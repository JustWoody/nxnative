"""pchtxt mods: the text patch format of IPSwitch, which Switch mod collections use for code and data patches of one NSO build.

A file names its build ("@nsobid-<build ID>", 32 or 40 hex digits; the module's 16-byte build ID is the first 32), may shift its offsets
("@flag offset_shift 0x100": offsets are then relative to the module image, the IPS patch adding the NSO header's 0x100), and holds patch
lines between "@enabled" (or "@disabled", skipped) and "@stop": "<offset> <hex bytes>", the bytes written in the order given, with //
comments. Quoted strings ("<offset> \"text\"") are written as UTF-8 with a terminating zero.

Folders: DM_PCHTXT (separated by os.pathsep), else <repo>/switchports/mods when it exists; every *.pchtxt below them counts, and only the
files whose @nsobid is a module's build ID apply to it (patch_nso.py, after the profile's cuts and before rewriting). A mod is the user's:
its bytes are not asserted against originals, which the file does not record; the rewriter then rewrites the patched code as any other.
"""
import glob, os, re

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '../..'))


def folders():
    e = os.environ.get('DM_PCHTXT')
    if e is not None:
        return [d for d in e.split(os.pathsep) if d]
    d = os.path.join(REPO, 'switchports', 'mods')
    return [d] if os.path.isdir(d) else []


def files():
    return sorted(p for d in folders() for p in glob.glob(os.path.join(glob.escape(d), '**', '*.pchtxt'), recursive=True))


def build_of(text):
    m = re.search(r'^@nsobid-([0-9A-Fa-f]{32,40})', text, re.M)
    return m.group(1)[:32].lower() if m else None


def patches(text):
    """[(module offset, bytes, comment)] of the enabled blocks"""
    shift = 0
    m = re.search(r'^@flag\s+offset_shift\s+(0x[0-9A-Fa-f]+|\d+)', text, re.M)
    if m: shift = int(m.group(1), 0)
    out, on = [], False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith('@enabled'): on = True; continue
        if s.startswith('@disabled') or s.startswith('@stop'): on = False; continue
        if not on or not s or s.startswith(('//', '#', '@')): continue
        body = s.split('//', 1)[0].strip()
        note = s.split('//', 1)[1].strip() if '//' in s else ''
        q = re.match(r'([0-9A-Fa-f]+)\s+"(.*)"$', body)
        h = None if q else re.match(r'([0-9A-Fa-f]+)\s+([0-9A-Fa-f]+)$', body)
        if q:
            data = q.group(2).encode('utf-8') + b'\0'
        elif h and len(h.group(2)) % 2 == 0:
            data = bytes.fromhex(h.group(2))
        else:
            raise ValueError(f'pchtxt line not understood: {line!r}')
        off = int((q or h).group(1), 16) + shift - 0x100   # the image offset: the IPS offset (written + shift) less the NSO header
        out.append((off, data, note))
    return out


def for_build(build_id):
    """[(path, [(offset, bytes, comment)])] of the mod files for one module build ID (32 hex digits)"""
    out = []
    for p in files():
        text = open(p, encoding='utf-8', errors='replace').read()
        if build_of(text) == build_id.lower():
            out.append((p, patches(text)))
    return out
