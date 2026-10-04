"""Public address detection should handle failures without touching a live install."""
import os
import ast
import ipaddress
import re
import pathlib
import types
import unittest
from unittest.mock import patch

source = (pathlib.Path(__file__).resolve().parents[1] / 's5.sh').read_text(encoding='utf-8')
source = source.split("<<'PY'\n", 1)[1].split('\nsignal.signal(signal.SIGTERM, interrupted)', 1)[0]
scope = dict(os=os, ipaddress=ipaddress, re=re)
tree = ast.parse(source)
names = {'Failure', 'fail', 'say', 'host_value', 'detect_public_host', 'resolve_public_host'}
tree.body = [node for node in tree.body if isinstance(node, (ast.ClassDef, ast.FunctionDef)) and node.name in names]
exec(compile(tree, 's5.sh', 'exec'), scope)


class PublicHostTests(unittest.TestCase):
    def test_detection_falls_back_and_rejects_private_addresses(self):
        results = iter([(60, 'certificate error'), (0, '10.0.0.1'), (0, '1.1.1.1\n')])
        calls = []
        def fake_run(args, **kwargs):
            calls.append(args)
            code, output = next(results)
            return types.SimpleNamespace(returncode=code, stdout=output)
        with patch.dict(scope, run=fake_run, say=lambda text: None):
            self.assertEqual(scope['detect_public_host'](), '1.1.1.1')
        self.assertEqual(len(calls), 3)
        self.assertIn('--ipv4', calls[0])

    def test_all_failures_include_reason_and_manual_override(self):
        def fake_run(args, **kwargs):
            return types.SimpleNamespace(returncode=6, stdout='Could not resolve host')
        with patch.dict(scope, run=fake_run):
            with self.assertRaisesRegex(scope['Failure'], 'PUBLIC_HOST.*') as error:
                scope['detect_public_host']()
        self.assertIn('Could not resolve host', str(error.exception))
        self.assertIn('exit=6', str(error.exception))

    def test_explicit_and_saved_host_do_not_require_network(self):
        def unexpected_network():
            self.fail('Should reuse explicit or saved address')
        with patch.dict(scope, detect_public_host=unexpected_network):
            with patch.dict(os.environ, PUBLIC_HOST='example.com'):
                self.assertEqual(scope['resolve_public_host']({'public_host': '1.1.1.1'}), 'example.com')
            with patch.dict(os.environ, PUBLIC_HOST=''):
                self.assertEqual(scope['resolve_public_host']({'public_host': '1.1.1.1'}), '1.1.1.1')


if __name__ == '__main__':
    unittest.main()
