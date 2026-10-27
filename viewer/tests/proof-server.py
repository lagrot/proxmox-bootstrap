"""Isolated boundary/failure tests; never contacts HA or Frigate."""
import importlib.util
from pathlib import Path
import unittest
from datetime import date, timezone
from io import BytesIO
import json
import threading
from urllib.error import HTTPError
from urllib.request import Request, urlopen

spec=importlib.util.spec_from_file_location('proof',Path(__file__).parents[1]/'proof/server.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

class FakeSources:
    def __init__(self): self.calls=[];self.fail=False
    def climate(self):
        self.calls.append('climate')
        if self.fail: raise p.UpstreamError('SECRET http://private-host/token')
        return {'temperature':{'value':10},'humidity':{'value':60}}
    def history(self,value,room_id='living'):
        p.day_bounds(value);self.calls.append('history');return {'temperature':[],'humidity':[]}
    def clip(self): return None
    def authorize_clip(self,event): self.calls.append('authorize');return False

class Boundaries(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources=FakeSources();cls.server=p.Server(('127.0.0.1',0),cls.sources)
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()
        cls.base='http://127.0.0.1:'+str(cls.server.server_port)
    @classmethod
    def tearDownClass(cls):cls.server.shutdown();cls.server.server_close();cls.thread.join()
    def setUp(self):self.sources.calls=[];self.sources.fail=False
    def request(self,path,headers=None,method='GET'):
        try:r=urlopen(Request(self.base+path,headers=headers or {},method=method),timeout=3)
        except HTTPError as e:r=e
        with r:return r.status,r.read(),r.headers
    def test_assets_explicit(self):
        self.assertEqual(self.request('/')[0],200)
        for path in ['/proof.js','/proof.css']:self.assertEqual(self.request(path)[0],200)
        for path in ['/config/local.conf','/server.py','/.git/config','/api/states','/api/services']:self.assertEqual(self.request(path)[0],404)
        self.assertFalse(self.sources.calls)
    def test_query_and_path_denial(self):
        for path in ['/api/live?url=http://evil','/api/climate?entity=sensor.other','/api/history?date=2026-10-01&date=2026-10-02','/api/history?url=x','/api/history?date=2099-01-01','/api/%2e%2e/config']:
            self.assertEqual(self.request(path)[0],400,path)
        self.assertFalse(self.sources.calls)
    def test_origin_and_host_denial(self):
        for headers in [{'Host':'evil.example'},{'Origin':'https://evil.example'},{'Sec-Fetch-Site':'cross-site'}]:
            self.assertEqual(self.request('/api/climate',headers)[0],403)
        self.assertFalse(self.sources.calls)
    def test_no_writes(self):
        for method in ['POST','PUT','PATCH','DELETE','OPTIONS']:self.assertEqual(self.request('/api/climate',method=method)[0],405)
        self.assertFalse(self.sources.calls)
    def test_errors_are_redacted(self):
        self.sources.fail=True;status,body,_=self.request('/api/climate');self.assertEqual(status,502)
        self.assertNotIn(b'SECRET',body);self.assertNotIn(b'private-host',body)
    def test_read_and_security_headers(self):
        status,body,h=self.request('/api/climate');self.assertEqual(status,200)
        self.assertEqual(h['Cache-Control'],'no-store');self.assertEqual(h['Cross-Origin-Resource-Policy'],'same-origin')
        self.assertNotIn('Access-Control-Allow-Origin',h);self.assertEqual(self.sources.calls,['climate'])
    def test_clip_empty_or_unknown(self):
        self.assertIsNone(json.loads(self.request('/api/clip')[1])['clip'])
        self.assertEqual(self.request('/api/clip/missing.mp4')[0],404)
    def test_vod_references_stay_local(self):
        from unittest.mock import patch
        def response(body):
            r=BytesIO(body);r.headers={};return r
        with patch.object(self.sources,'authorize_clip',return_value=True):
            with patch.object(self.sources,'open',create=True,return_value=response(b'#EXTM3U\n#EXT-X-MAP:URI="init-v1-a1.mp4"\nseg-1-v1-a1.m4s\n')):
                code,body,_=self.request('/api/vod/test/index.m3u8')
                self.assertEqual(code,200);self.assertNotIn(b'http:',body)
            for raw in [b'#EXTM3U\nhttp://evil/seg-1-v1.m4s',b'#EXTM3U\n#EXT-X-MAP:URI="../private.mp4"']:
                with patch.object(self.sources,'open',create=True,return_value=response(raw)):
                    code,body,_=self.request('/api/vod/test/index.m3u8')
                    self.assertEqual(code,502);self.assertNotIn(b'evil',body)
            with patch.object(self.sources,'open',create=True) as opened:
                self.assertEqual(self.request('/api/vod/test/arbitrary.mp4')[0],404)
                opened.assert_not_called()
    def test_immediate_restart_after_connection(self):
        server=p.Server(('127.0.0.1',0),FakeSources())
        port=server.server_port
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        with urlopen('http://127.0.0.1:'+str(port)+'/api/climate',timeout=3) as r:
            r.read()
        server.shutdown();server.server_close();thread.join()
        replacement=p.Server(('127.0.0.1',port),FakeSources())
        replacement.server_close()
        # SO_REUSEADDR must not replace an actively listening server.
        with self.assertRaises(OSError):
            p.Server(('127.0.0.1',self.server.server_port),FakeSources())
    def test_nine_latest_across_both_cameras(self):
        s=p.Sources('http://192.168.1.1','http://192.168.1.2','TEST-ONLY')
        events=[{'id':f'event{i}','camera':list(p.CAMERAS.values())[i%2]['entity'],
                 'has_clip':True,'start_time':i,'end_time':i+2} for i in range(20)]
        events += [{'id':'wrong','camera':'other','has_clip':True,'start_time':100,'end_time':102},
                   {'id':'ongoing','camera':p.CAMERA,'has_clip':True,'start_time':101,'end_time':None}]
        s.json=lambda *args:events
        result=s.clips()
        self.assertEqual(len(result),9)
        self.assertEqual([x['started'] for x in result],list(map(float,range(19,10,-1))))
        self.assertEqual({x['camera'] for x in result},{'c200','c320'})
        self.assertEqual(len(s.issued),9)
        self.assertNotIn('wrong',s.issued)
    def test_outside_and_rolling_day_scope(self):
        s=p.Sources('http://192.168.1.1','http://192.168.1.2','TEST-ONLY')
        paths=[]
        def read(source,path): paths.append(path);return []
        s.json=read
        result=s.history('24h','outside')
        self.assertFalse(result['humidity'])
        self.assertEqual((p.datetime.fromisoformat(result['end'])-p.datetime.fromisoformat(result['start'])).total_seconds(),86400)
        from urllib.parse import parse_qs,urlsplit
        self.assertEqual(parse_qs(urlsplit(paths[0]).query)['filter_entity_id'],[p.ROOMS['outside']['temperature']])
    def test_dates_dst_and_windows(self):
        start,end=p.day_bounds('2026-10-25',date(2026,10,27))
        self.assertEqual((end.astimezone(timezone.utc)-start.astimezone(timezone.utc)).total_seconds(),25*3600)
        start,end=p.day_bounds('2026-03-29',date(2026,3,30))
        self.assertEqual((end.astimezone(timezone.utc)-start.astimezone(timezone.utc)).total_seconds(),23*3600)
        for value in ['2026-02-30','2026-1-1','2026-10-28','2026-10-17','http://evil']:
            with self.assertRaises(ValueError):p.day_bounds(value,date(2026,10,27))
    def test_unavailable_values_and_origins(self):
        for value in ['unavailable','unknown',None,'nan','inf']:self.assertIsNone(p.number(value))
        self.assertEqual(p.number('10.5'),10.5)
        for origin in ['https://example.com','http://8.8.8.8','http://192.168.1.2/path','http://user:pass@192.168.1.2']:
            with self.assertRaises(ValueError):p.validate_origin(origin)
    def test_history_filters_and_gaps(self):
        s=p.Sources('http://192.168.1.1','http://192.168.1.2','TEST-ONLY')
        today=p.datetime.now(p.ZONE).date().isoformat()
        start,end=p.day_bounds(today)
        rows=[[{'entity_id':p.TEMPERATURE,'last_changed':start.isoformat(),'state':'unavailable'},
               {'last_changed':(start+p.timedelta(minutes=1)).isoformat(),'state':'10.2'}],
              [{'entity_id':'sensor.not_allowed','last_changed':start.isoformat(),'state':'99'}]]
        s.json=lambda *args:rows
        result=s.history(today);self.assertEqual(result['temperature'][0]['value'],None)
        self.assertEqual(len(result['temperature']),2);self.assertFalse(result['humidity'])
    def test_wrong_camera_and_running_events(self):
        s=p.Sources('http://192.168.1.1','http://192.168.1.2','TEST-ONLY')
        events=[{'id':'foreign','camera':'other','has_clip':True,'start_time':1,'end_time':2},
                {'id':'running','camera':p.CAMERA,'has_clip':True,'start_time':3,'end_time':None}]
        s.json=lambda *args:events
        self.assertIsNone(s.clip())

if __name__=='__main__':unittest.main(verbosity=2)
