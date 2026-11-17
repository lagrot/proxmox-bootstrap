#!/usr/bin/env python3
"""Classify gateway logs without printing potentially sensitive log content."""
import re
import sys

lines = sys.stdin.read().splitlines()
fatal = re.compile(r'Main process exited|Failed with result|(?:^|\s)(?:CRITICAL|FATAL)(?::|\s)|unhandled exception', re.I)
trace = 'Traceback (most recent call last)'
handled = 0
errors = 0
for index, line in enumerate(lines):
    if fatal.search(line):
        errors += 1
    if trace not in line:
        continue
    # A Python traceback ends with its exception line. Never look past the
    # next traceback or a separate timestamped log message for an exception.
    exception = None
    for following in lines[index + 1:index + 101]:
        message = following.split(': ', 1)[-1]
        if trace in following or re.match(r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d[, ]', message):
            break
        if re.match(r'^[\w.]+(?:Error|Exception)(?::|$)', message):
            exception = message
            break
    if exception and re.match(r'^openai\.RateLimitError: Error code: 429\b', exception):
        handled += 1
    else:
        errors += 1
print(f'{errors} {handled}')
