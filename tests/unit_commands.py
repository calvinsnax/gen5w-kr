#!/usr/bin/env python3
"""Static check: on-unit shell scripts only use commands and options the head unit has.

The unit runs mksh R43 with a KitKat toolbox. The mock tests run on a PC with
GNU tools, so a missing command (printf, head, sed, ...) or an option toolbox
lacks (mv -f, cmp -s) would pass there and fail in the car. This check reads
tests/unit/commands.txt and tests/unit/policy.txt and rejects anything else.

It tokenizes each script the way a shell does (quotes, $(...), case labels,
here-documents) and checks every word in command position. Commands built at
run time ("$tool" ...) cannot be checked here; tests/unit/shim.sh covers those
while the mock tests run.
"""
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
UNIT_DIR = ROOT / 'tests' / 'unit'

# On-unit scripts: package hooks, package binaries, the USB installer and the probe.
SCRIPT_GLOBS = [
    'packages/*/scripts/*.sh', 'packages/*/bin/*.sh',
    'tools/integrated/*.sh',
    'tools/usb-wifi/package/scripts/*.sh', 'tools/usb-wifi/package/bin/*',
    'tools/usb-wifi/scripts/*.sh',
    'probe/package/bin/*.sh', 'probe/usb/*/*.sh',
    'tools/stock-dump/*.sh',
]

# mksh R43 builtins and default aliases.
BUILTINS = set('''
. : [ alias break builtin cat cd chdir command continue echo eval exec exit export
false fc getopts global jobs kill let print pwd read realpath readonly rename return
set shift sleep source suspend test times trap true typeset ulimit umask unalias
unset wait whence bg fg bind mknod
autoload functions hash history integer local login nameref r type
'''.split())
# Words after which the next word is again in command position.
LEAD = {'if', 'then', 'else', 'elif', 'while', 'until', 'do', '!', '{', 'time'}
CLOSE = {'fi', 'done', 'esac', '}'}


def load_commands():
    commands, toolbox = set(), set()
    for line in (UNIT_DIR / 'commands.txt').read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        commands.add(parts[0])
        if parts[1:] == ['toolbox']:
            toolbox.add(parts[0])
    return commands, toolbox


def load_policy():
    options, letters, banned = {}, {}, {}
    for line in (UNIT_DIR / 'policy.txt').read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('!'):
            name, _, reason = line[1:].partition(' ')
            banned[name] = reason
            continue
        parts = line.split()
        options.setdefault(parts[0], set())
        for word in parts[1:]:
            if word.startswith('+'):
                letters[parts[0]] = set(word[1:])
            else:
                options[parts[0]].add(word)
    return options, letters, banned


SKIP_DIRS = {'.git', 'tests', 'dist', '__pycache__', 'node_modules', 'build', 'analysis_private'}


def shebang_scripts(top, skip):
    """Every file under top that starts with #!/system/bin/sh."""
    found = []
    for dirpath, dirnames, filenames in os.walk(top):
        dirnames[:] = sorted(d for d in dirnames if d not in skip)
        for name in sorted(filenames):
            path = pathlib.Path(dirpath) / name
            if path.is_symlink():
                continue
            try:
                with path.open('rb') as f:
                    if f.read(16).startswith(b'#!/system/bin/sh'):
                        found.append(path)
            except OSError:
                continue
    return found


def script_files(dist=False):
    """Sourced on-unit files (no shebang) from SCRIPT_GLOBS plus every source file
    that starts with #!/system/bin/sh. With dist=True: the shell files of the built
    trees in dist/ (CI runs this right after a fresh build; it also covers the
    generated NEMESIS.sh)."""
    if dist:
        top = ROOT / 'dist'
        files = shebang_scripts(top, {'__pycache__'})
        files += [p for p in sorted(top.rglob('*.sh')) if p not in files and p.is_file()]
        return files
    found = []
    for pattern in SCRIPT_GLOBS:
        for path in sorted(ROOT.glob(pattern)):
            if not path.is_file() or path in found:
                continue
            head = path.read_bytes()[:64]
            if b'\0' in head:
                continue
            if path.suffix == '.sh' or head.startswith(b'#!/system/bin/sh'):
                found.append(path)
    try:  # tracked files only: local build leftovers are not sources
        tracked = subprocess.run(['git', 'ls-files', '-z'], cwd=ROOT, check=True,
                                 capture_output=True).stdout.decode().split('\0')
    except (OSError, subprocess.CalledProcessError):
        tracked = None
    if tracked is None:
        candidates = shebang_scripts(ROOT, SKIP_DIRS)
    else:
        candidates = []
        for rel in tracked:
            path = ROOT / rel
            if not rel or rel.split('/')[0] in SKIP_DIRS or path.is_symlink() or not path.is_file():
                continue
            with path.open('rb') as f:
                if f.read(16).startswith(b'#!/system/bin/sh'):
                    candidates.append(path)
    found += [p for p in candidates if p not in found]
    return found


class Word:
    """One shell word: its literal text (None if any part is dynamic) and line."""
    def __init__(self, line):
        self.line = line
        self.text = ''
        self.dynamic = False
        self.quoted = False
        self.prefix = ''   # leading unquoted, literal text (NAME= of an assignment)

    def value(self):
        return None if self.dynamic else self.text


class Lexer:
    """Splits shell text into commands (lists of Words), recursing into $(...) and `...`."""

    def __init__(self, text, line=1):
        self.s = text
        self.i = 0
        self.line = line
        self.commands = []

    def peek(self, k=0):
        j = self.i + k
        return self.s[j] if j < len(self.s) else ''

    def advance(self, n=1):
        for _ in range(n):
            if self.i < len(self.s) and self.s[self.i] == '\n':
                self.line += 1
            self.i += 1

    def skip_balanced(self, open_ch, close_ch):
        """Skip to the matching close (cursor just after the opener), honouring quotes."""
        depth = 1
        while self.i < len(self.s) and depth:
            c = self.peek()
            if c == '\\':
                self.advance(2)
                continue
            if c == "'":
                self.advance()
                while self.i < len(self.s) and self.peek() != "'":
                    self.advance()
                self.advance()
                continue
            if c == '"':
                self.advance()
                self.read_double(Word(self.line))
                continue
            if c == open_ch:
                depth += 1
            elif c == close_ch:
                depth -= 1
            self.advance()

    def substitution(self, closer):
        """Lex a command substitution body; its commands join ours."""
        start, line = self.i, self.line
        if closer == ')':
            self.skip_balanced('(', ')')
            body = self.s[start:self.i - 1]
        else:
            while self.i < len(self.s) and self.peek() != '`':
                self.advance(2 if self.peek() == '\\' else 1)
            body = self.s[start:self.i]
            self.advance()
        inner = Lexer(body, line)
        inner.run()
        self.commands.extend(inner.commands)

    def dollar(self, word):
        """At '$': consume one expansion. Marks the word dynamic."""
        word.dynamic = True
        nxt = self.peek(1)
        if nxt == '(' and self.peek(2) == '(':
            self.advance(3)
            self.skip_balanced('(', ')')
            if self.peek() == ')':
                self.advance()
        elif nxt == '(':
            self.advance(2)
            self.substitution(')')
        elif nxt == '{':
            self.advance(2)
            self.skip_balanced('{', '}')
        elif nxt == "'":
            self.advance(2)
            while self.i < len(self.s) and self.peek() != "'":
                self.advance(2 if self.peek() == '\\' else 1)
            self.advance()
        else:
            self.advance()
            while self.peek() and (self.peek().isalnum() or self.peek() == '_'):
                self.advance()
            if self.peek() and self.peek() in '?$#!@*-0123456789' and self.s[self.i - 1] == '$':
                self.advance()

    def read_double(self, word):
        word.quoted = True
        while self.i < len(self.s):
            c = self.peek()
            if c == '"':
                self.advance()
                return
            if c == '\\':
                word.text += self.peek(1)
                self.advance(2)
            elif c == '$':
                self.dollar(word)
            elif c == '`':
                word.dynamic = True
                self.advance()
                self.substitution('`')
            else:
                word.text += c
                self.advance()

    def tokens(self):
        """Yield Words and operator strings."""
        while self.i < len(self.s):
            c = self.peek()
            if c in ' \t':
                self.advance()
                continue
            if c == '\\' and self.peek(1) == '\n':
                self.advance(2)
                continue
            if c == '#':
                while self.i < len(self.s) and self.peek() != '\n':
                    self.advance()
                continue
            if c == '\n':
                yield ('\n', self.line)
                self.advance()
                continue
            two = self.s[self.i:self.i + 2]
            if two in ('&&', '||', ';;', '((', '))'):
                yield (two, self.line)
                self.advance(2)
                continue
            if c in ';&|()':
                yield (c, self.line)
                self.advance()
                continue
            if c in '<>':
                # redirection: operator plus its target word are skipped
                while self.peek() in '<>&':
                    self.advance()
                while self.peek() in ' \t':
                    self.advance()
                self.read_word(Word(self.line))
                continue
            word = Word(self.line)
            self.read_word(word)
            # a word like 2>/dev/null: fd number glued to a redirection
            if not word.quoted and re.fullmatch(r'[0-9]+', word.text or '') and self.peek() in '<>':
                continue
            yield word

    def read_word(self, word):
        while self.i < len(self.s):
            c = self.peek()
            if c in ' \t\n;&|()<>':
                if c in '<>' and not word.text and not word.dynamic:
                    pass
                break
            if c == '\\':
                word.text += self.peek(1)
                self.advance(2)
            elif c == "'":
                word.quoted = True
                self.advance()
                while self.i < len(self.s) and self.peek() != "'":
                    word.text += self.peek()
                    self.advance()
                self.advance()
            elif c == '"':
                self.advance()
                self.read_double(word)
            elif c == '$':
                self.dollar(word)
            elif c == '`':
                word.dynamic = True
                self.advance()
                self.substitution('`')
            else:
                word.text += c
                if not word.quoted and not word.dynamic:
                    word.prefix += c
                self.advance()

    def run(self):
        current = []
        case_stack = []      # per open 'case': 'subject' | 'patterns' | 'body'
        mode = 'cmd'         # 'cmd' | 'args' | 'for' | 'test'
        pending_fn = None

        def finish():
            nonlocal current
            if current:
                self.commands.append(current)
            current = []

        for tok in self.tokens():
            if isinstance(tok, tuple):
                op, _ = tok
                if case_stack and case_stack[-1] == 'patterns':
                    if op == ')':
                        case_stack[-1] = 'body'
                        mode = 'cmd'
                    continue
                if op == ';;':
                    finish()
                    if case_stack:
                        case_stack[-1] = 'patterns'
                    continue
                if op == '(' and pending_fn is not None:
                    continue
                if op == ')' and pending_fn is not None:
                    pending_fn = None
                    current = []
                    mode = 'cmd'
                    continue
                if op in ('((', '))'):
                    continue
                finish()
                if mode != 'for' or op in ('\n', ';'):
                    mode = 'cmd'
                continue
            word = tok
            val = word.value()
            if case_stack and case_stack[-1] == 'subject':
                if val == 'in':
                    case_stack[-1] = 'patterns'
                continue
            if case_stack and case_stack[-1] == 'patterns':
                if val == 'esac':
                    case_stack.pop()
                    mode = 'args'
                elif val and val.endswith(')') and not word.quoted:
                    case_stack[-1] = 'body'
                    mode = 'cmd'
                continue
            if mode == 'test':
                if val == ']]':
                    mode = 'args'
                continue
            if mode == 'for':
                if val == 'do':
                    mode = 'cmd'
                continue
            if mode == 'cmd':
                if val in LEAD:
                    continue
                if val in CLOSE:
                    if val == 'esac' and case_stack:
                        case_stack.pop()
                    mode = 'args'
                    continue
                if val == 'case':
                    case_stack.append('subject')
                    continue
                if val in ('for', 'select'):
                    mode = 'for'
                    continue
                if val == '[[':
                    mode = 'test'
                    continue
                if val == 'function':
                    pending_fn = ''
                    continue
                if re.match(r'[A-Za-z_][A-Za-z0-9_]*=', word.prefix):
                    continue  # assignment prefix
                if val is not None and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]*', val):
                    pending_fn = val  # maybe 'name()'
                current = [word]
                mode = 'args'
                continue
            # args
            if pending_fn is not None and current and len(current) == 1:
                pending_fn = None
            if val in CLOSE and not word.quoted and val == 'esac' and case_stack:
                case_stack.pop()
                continue
            current.append(word)
        finish()


class Linter:
    def __init__(self):
        self.commands, self.toolbox = load_commands()
        self.options, self.letters, self.banned = load_policy()
        self.errors = []

    def error(self, where, message):
        self.errors.append(f'{where}: {message}')

    def check_command(self, rel, words, functions):
        where = f'{rel}:{words[0].line}'
        # command / exec / builtin prefixes
        while len(words) > 1 and words[0].value() in ('command', 'exec', 'builtin', 'nohup') \
                and not (words[1].value() or '').startswith('-'):
            if words[0].value() == 'nohup':
                self.error(where, "'nohup' is not on the head unit")
            words = words[1:]
        # inner command strings: sh -c '...', nemesis root -c '...'
        for k in range(1, len(words) - 1):
            if words[k].value() == '-c' and words[k + 1].value() is not None:
                inner = Lexer(words[k + 1].value(), words[k + 1].line)
                inner.run()
                for c in inner.commands:
                    self.check_command(rel, c, functions)
                break
        cmd = words[0].value()
        if cmd is None:
            return  # built at run time; the shim checks it during the tests
        if '/' in cmd:
            if not cmd.startswith('/system/'):
                return  # our own scripts and binaries
            cmd = cmd.rsplit('/', 1)[-1]
        if cmd in self.banned:
            self.error(where, f"'{cmd}': {self.banned[cmd]}")
            return
        if cmd in functions or cmd in BUILTINS:
            return
        if cmd not in self.commands:
            self.error(where, f"'{cmd}' is not a command on the head unit")
            return
        if cmd not in self.toolbox:
            return
        allowed = self.options.get(cmd, set())
        letters = self.letters.get(cmd)
        for w in words[1:]:
            v = w.value()
            if v is None or not v.startswith('-') or v == '-':
                break  # options end at the first operand
            if v in allowed or (letters and re.fullmatch(r'-[A-Za-z]+', v) and set(v[1:]) <= letters):
                continue
            self.error(where, f"'{cmd} {v}': the unit's toolbox {cmd} does not take {v}")

    def run(self, dist=False):
        files = script_files(dist)
        parsed, functions = [], set()
        for path in files:
            text = path.read_text(encoding='utf-8', errors='replace')
            text = drop_heredocs(text)
            functions.update(re.findall(r'(?m)^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)', text))
            lexer = Lexer(text)
            lexer.run()
            parsed.append((path.relative_to(ROOT), lexer.commands))
        for rel, commands in parsed:
            for words in commands:
                self.check_command(rel, words, functions)
        return files


def drop_heredocs(text):
    """Blank out here-document bodies (keeping line numbers)."""
    out, lines, i = [], text.split('\n'), 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z0-9_]+)\1", line)
        if m and not re.search(r"<<<", line):
            end = m.group(2)
            while i < len(lines) and lines[i].strip() != end:
                out.append('')
                i += 1
            if i < len(lines):
                out.append('')
                i += 1
    return '\n'.join(out)


SELF_TEST = [
    # (snippet, expected number of problems)
    ("printf '%s' x", 1),
    ("mv -f a b", 1),
    ("mv a b && cmp -s a b", 1),
    ("v=$(head -n 1 f)", 1),
    ('echo "rev: $(cut -c1-7 f)"', 1),
    ("getprop x | tr -d '\r' | sed 's/a/b/'", 2),
    ("nemesis root -c 'sed -i s/a/b/ f'", 1),
    ("case $x in a|b) md5sum f;; *) md5 f;; esac", 1),
    ("if ! timeout 5 foo; then :; fi", 1),
    ("grep -P x f", 1),
    ("busybox ls", 1),
    ("echo 'a; head | sed'; echo \"x | tr\"", 0),
    ("X=\"$(md5 f)\" Y='a|b' cp -p a b", 0),
    ("grep -aqE 'a|b' f && grep -qxF a f && mv a b && cmp a b >/dev/null 2>&1", 0),
    ("f() { local v; v=${x//a/b}; print -r -- \"${v:0:3}\"; }; f", 0),
    ("for i in head sed; do echo $i; done", 0),
    ("while IFS= read -r line; do sleep 1; done < f", 0),
    ("[[ $a == b* ]] && ls -ln f", 0),
]


def self_test():
    failed = 0
    for snippet, expected in SELF_TEST:
        linter = Linter()
        lexer = Lexer(snippet)
        lexer.run()
        functions = set(re.findall(r'([A-Za-z_][A-Za-z0-9_]*)\s*\(\)', snippet))
        for words in lexer.commands:
            linter.check_command('self-test', words, functions)
        if len(linter.errors) != expected:
            failed += 1
            print(f'FAIL self-test {snippet!r}: {len(linter.errors)} problem(s), expected {expected}: {linter.errors}')
    return failed


def main():
    if sys.argv[1:] == ['--list']:
        for path in script_files():
            print(path.relative_to(ROOT).as_posix())
        return 0
    dist = sys.argv[1:] == ['--dist']
    if self_test():
        return 1
    linter = Linter()
    files = linter.run(dist)
    what = 'built on-unit scripts in dist/' if dist else 'on-unit scripts'
    if dist and not files:
        print('FAIL unit commands: no built scripts in dist/ (run tools/build-all.sh first)')
        return 1
    for e in linter.errors:
        print(f'FAIL {e}')
    if linter.errors:
        print(f'== unit commands: {len(linter.errors)} problem(s) in {len(files)} {what}')
        return 1
    print(f'PASS unit commands: {len(files)} {what} use only head-unit commands and options')
    return 0


if __name__ == '__main__':
    sys.exit(main())
