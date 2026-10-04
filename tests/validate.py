"""Validate syntax without running the privileged installer."""
import ast
import pathlib

path = pathlib.Path(__file__).resolve().parents[1] / 's5.sh'
raw = path.read_bytes()
assert b'\r' not in raw, 'Script must use LF endings'
source = raw.decode().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
ast.parse(source)
print('Embedded Python syntax and LF endings: OK')
