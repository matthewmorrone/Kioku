#!/usr/bin/env python3
"""Invariant 2 (no silently swallowed failures), beyond the literal empty `catch {}`.

Flags, as path:line: message:
  - a guard/if on an SQLite result code whose failure branch neither throws nor logs
  - `while sqlite3_step(...) == SQLITE_ROW` loops, which drop the final step code (an error
    reads as end-of-rows); step into a variable and check SQLITE_DONE after the loop
  - catch blocks that are empty, comment-only, or only return/continue/break a default
    (`catch is CancellationError` is exempt: cancellation is not a failure)
  - tables named in the app's SQL that neither Resources/generate_db.py nor the app's own
    CREATE TABLE statements create (CTE names are exempt)

Usage: check_swallowed_failures.py [swift files...]   (no args = every Swift file under Kioku/)
Exit status 1 when anything is flagged.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRACE = re.compile(r'\b(throw|AppLog\.|fatalError|preconditionFailure|assertionFailure)\b')
SQLITE_RESULT = re.compile(r'[=!]=\s*SQLITE_(?!NULL\b|INTEGER\b|TEXT\b|BLOB\b|FLOAT\b)[A-Z_]+')
DEFAULT_ONLY = re.compile(
    r'^(?:(?:return(?:\s+(?:nil|true|false|\[\]|\[:\]|-?\d+(?:\.\d+)?|""|\.\w+|\w+\(\)|\(\w+,\s*\w+\)))?|continue|break)\s*;?\s*)+$'
)


def strip_comments(text):
    """Blank out // and /* */ comments and string contents, keeping offsets and newlines."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            for k in range(i + 3, j - 3):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == '\\' else 1
            for k in range(i + 1, min(j, n)):
                out[k] = ' '
            i = j + 1
        else:
            i += 1
    return ''.join(out)


def matching_brace(code, open_index):
    """Index of the brace closing the one at open_index, or -1."""
    depth = 0
    for i in range(open_index, len(code)):
        if code[i] == '{':
            depth += 1
        elif code[i] == '}':
            depth -= 1
            if depth == 0:
                return i
    return -1


def line_of(code, index):
    return code.count('\n', 0, index) + 1


def check_sqlite_guards(path, code, report):
    """guard/if on an SQLite result code whose failure branch leaves no trace."""
    for m in re.finditer(r'\bguard\b', code):
        else_match = re.compile(r'\belse\s*\{').search(code, m.end())
        if not else_match:
            continue
        condition = code[m.end():else_match.start()]
        if '{' in condition or not SQLITE_RESULT.search(condition):
            continue
        close = matching_brace(code, else_match.end() - 1)
        if close > 0 and not TRACE.search(code[else_match.end():close]):
            report(path, line_of(code, m.start()), 'SQLite failure branch returns without throwing or logging')
    for m in re.finditer(r'\bif\b([^{\n]*!=\s*SQLITE_(?:OK|DONE|ROW)\b[^{\n]*)\{', code):
        if '==' in m.group(1):
            continue
        close = matching_brace(code, m.end() - 1)
        if close > 0 and not TRACE.search(code[m.end():close]):
            report(path, line_of(code, m.start()), 'SQLite failure branch returns without throwing or logging')
    for m in re.finditer(r'\bwhile\s+sqlite3_step\(', code):
        report(path, line_of(code, m.start()), 'while sqlite3_step(...) drops the final step code; check SQLITE_DONE after the loop')


def check_catches(path, code, report):
    """catch blocks that are empty, comment-only, or only return a default."""
    for m in re.finditer(r'\bcatch\b([^{\n]*)\{', code):
        if 'CancellationError' in m.group(1):
            continue
        close = matching_brace(code, m.end() - 1)
        if close < 0:
            continue
        body = ' '.join(code[m.end():close].split())
        if body == '':
            report(path, line_of(code, m.start()), 'catch block is empty or comment-only')
        elif DEFAULT_ONLY.match(body):
            report(path, line_of(code, m.start()), 'catch block only returns a default; log or rethrow')


def sql_literals(text):
    """(offset, content) of every string literal that looks like SQL."""
    for m in re.finditer(r'"""(.*?)"""|"((?:[^"\\\n]|\\.)*)"', text, re.S):
        content = m.group(1) if m.group(1) is not None else m.group(2)
        if re.search(r'\b(SELECT|INSERT|UPDATE|DELETE|CREATE)\b', content):
            yield m.start(), content


def created_tables(swift_texts):
    """Tables generate_db.py or the app itself creates, plus every CTE name the app defines."""
    names = {'sqlite_master', 'sqlite_schema'}
    create = re.compile(r'CREATE\s+(?:VIRTUAL\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)', re.I)
    names.update(create.findall((ROOT / 'Resources' / 'generate_db.py').read_text()))
    for text in swift_texts:
        for _, sql in sql_literals(text):
            names.update(create.findall(sql))
            names.update(re.findall(r'(?:\bWITH\s+(?:RECURSIVE\s+)?|,\s*)(\w+)\s*(?:\([^)]*\))?\s+AS\s*\(', sql))
    return names


def check_tables(path, text, known, report):
    """SQL naming a table that nothing creates."""
    for offset, sql in sql_literals(text):
        for m in re.finditer(r'\b(?:FROM|JOIN|INTO|UPDATE|TABLE(?:\s+IF\s+NOT\s+EXISTS)?)\s+([a-z_][a-z0-9_]*)\b', sql):
            if m.group(1) not in known:
                report(path, line_of(text, offset) + sql.count('\n', 0, m.start()),
                       f'SQL names table "{m.group(1)}", which generate_db.py never creates')


def main(argv):
    all_files = sorted((ROOT / 'Kioku').rglob('*.swift'))
    targets = [Path(a).resolve() for a in argv] if argv else all_files
    texts = {p: p.read_text() for p in all_files}
    known = created_tables(texts.values())
    findings = []

    def report(path, line, message):
        findings.append(f'{path.relative_to(ROOT)}:{line}: {message}')

    for path in targets:
        if path.suffix != '.swift' or not path.is_file():
            continue
        text = texts.get(path) or path.read_text()
        code = strip_comments(text)
        check_sqlite_guards(path, code, report)
        check_catches(path, code, report)
        check_tables(path, text, known, report)

    print('\n'.join(findings)) if findings else None
    return 1 if findings else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
