#!/usr/bin/env python3
"""Chrome Agent MCP server.

Exposes a consent-gated Chrome DevTools connection to opencode. The safety
boundary is the enable flag written by KySettings; without it every tool
refuses, regardless of whether a debug port happens to be open.
"""
import base64
import json
import os
import sys
import time
import urllib.request

import websocket

BASE = os.path.expanduser(os.environ.get('CHROME_AGENT_BASE', '~/.config/chrome-agent'))
FLAG = os.path.join(BASE, 'enabled')
PORT = int(os.environ.get('CHROME_AGENT_PORT', '9223'))
DEBUG_URL = f'http://127.0.0.1:{PORT}'
SERVER_NAME = 'chrome-agent'
SERVER_VERSION = '0.1.0'

TOOLS = [
    {
        'name': 'chrome_status',
        'description': 'Report whether Chrome agent access is enabled and the debug port is live.',
        'inputSchema': {'type': 'object', 'properties': {}},
    },
    {
        'name': 'chrome_tabs',
        'description': 'List open tabs in the agent Chrome profile.',
        'inputSchema': {'type': 'object', 'properties': {}},
    },
    {
        'name': 'chrome_navigate',
        'description': 'Navigate a tab (or the active tab) to a URL and wait for load.',
        'inputSchema': {
            'type': 'object',
            'properties': {
                'url': {'type': 'string'},
                'tab_id': {'type': 'string', 'description': 'Target tab id; default active tab'},
            },
            'required': ['url'],
        },
    },
    {
        'name': 'chrome_eval',
        'description': 'Evaluate a JavaScript expression in a tab and return the value.',
        'inputSchema': {
            'type': 'object',
            'properties': {
                'expression': {'type': 'string'},
                'tab_id': {'type': 'string'},
                'await_promise': {'type': 'boolean', 'default': True},
            },
            'required': ['expression'],
        },
    },
    {
        'name': 'chrome_console',
        'description': 'Collect console messages and exceptions from a tab for a short window.',
        'inputSchema': {
            'type': 'object',
            'properties': {
                'tab_id': {'type': 'string'},
                'wait_ms': {'type': 'integer', 'default': 2500, 'maximum': 15000},
            },
        },
    },
    {
        'name': 'chrome_screenshot',
        'description': 'Capture a PNG screenshot of a tab.',
        'inputSchema': {
            'type': 'object',
            'properties': {'tab_id': {'type': 'string'}},
        },
    },
]


def log(message):
    print(f'[{SERVER_NAME}] {message}', file=sys.stderr, flush=True)


def enabled():
    return os.path.isfile(FLAG)


def debug_targets():
    with urllib.request.urlopen(f'{DEBUG_URL}/json', timeout=3) as response:
        return json.load(response)


def pick_page(tab_id=None):
    pages = [t for t in debug_targets() if t.get('type') == 'page']
    if not pages:
        raise RuntimeError('no page tabs are open in the agent profile')
    if tab_id:
        for page in pages:
            if page.get('id') == tab_id:
                return page
        raise RuntimeError(f'tab {tab_id!r} not found')
    for page in pages:
        if page.get('url') == 'about:blank' or page.get('attached'):
            return page
    return pages[0]


class CDP:
    def __init__(self, ws_url):
        self.ws = websocket.create_connection(ws_url, timeout=10, suppress_origin=True)
        self.next_id = 0

    def send(self, method, params=None):
        self.next_id += 1
        message_id = self.next_id
        self.ws.send(json.dumps({'id': message_id, 'method': method, 'params': params or {}}))
        while True:
            message = json.loads(self.ws.recv())
            if message.get('id') == message_id:
                return message

    def collect_events(self, seconds):
        events = []
        self.ws.settimeout(0.25)
        end = time.time() + seconds
        while time.time() < end:
            try:
                message = json.loads(self.ws.recv())
            except Exception:
                continue
            method = message.get('method')
            params = message.get('params', {})
            if method == 'Runtime.consoleAPICalled':
                values = []
                for item in params.get('args', []):
                    values.append(str(item.get('value', item.get('description', '')))[:400])
                events.append({'kind': params.get('type'), 'values': values})
            elif method == 'Runtime.exceptionThrown':
                details = params.get('exceptionDetails', {})
                text = details.get('exception', {}).get('description', details.get('text', ''))
                events.append({'kind': 'exception', 'text': str(text)[:800]})
            elif method == 'Log.entryAdded':
                entry = params.get('entry', {})
                events.append({'kind': f"log-{entry.get('level')}", 'text': entry.get('text', '')[:800]})
        return events

    def close(self):
        self.ws.close()


def tool_status():
    running = False
    tab_count = 0
    detail = 'debug port not reachable'
    try:
        targets = debug_targets()
        running = True
        tab_count = len([t for t in targets if t.get('type') == 'page'])
        detail = 'debug port live'
    except Exception as error:
        detail = f'debug port not reachable: {error}'
    return {
        'enabled': enabled(),
        'chrome_running': running,
        'tabs': tab_count,
        'port': PORT,
        'detail': detail,
    }


def tool_tabs():
    return [
        {'id': t.get('id'), 'title': t.get('title'), 'url': t.get('url')}
        for t in debug_targets() if t.get('type') == 'page'
    ]


def tool_navigate(arguments):
    page = pick_page(arguments.get('tab_id'))
    cdp = CDP(page['webSocketDebuggerUrl'])
    try:
        cdp.send('Page.enable')
        cdp.send('Page.navigate', {'url': arguments['url']})
        deadline = time.time() + 20
        state = ''
        while time.time() < deadline:
            time.sleep(0.4)
            result = cdp.send('Runtime.evaluate',
                              {'expression': 'document.readyState', 'returnByValue': True})
            state = result.get('result', {}).get('result', {}).get('value', '')
            if state == 'complete':
                break
        info = cdp.send('Runtime.evaluate',
                        {'expression': '({url: location.href, title: document.title})',
                         'returnByValue': True})
        value = info.get('result', {}).get('result', {}).get('value', {})
        return {'url': value.get('url', arguments['url']),
                'title': value.get('title', ''), 'ready_state': state}
    finally:
        cdp.close()


def tool_eval(arguments):
    page = pick_page(arguments.get('tab_id'))
    cdp = CDP(page['webSocketDebuggerUrl'])
    try:
        result = cdp.send('Runtime.evaluate', {
            'expression': arguments['expression'],
            'returnByValue': True,
            'awaitPromise': bool(arguments.get('await_promise', True)),
        })
        payload = result.get('result', {})
        if 'exceptionDetails' in payload:
            return {'error': payload['exceptionDetails'].get('text', 'evaluation failed')}
        remote = payload.get('result', {})
        return {'type': remote.get('type'), 'value': remote.get('value'),
                'description': remote.get('description')}
    finally:
        cdp.close()


def tool_console(arguments):
    page = pick_page(arguments.get('tab_id'))
    wait_ms = min(int(arguments.get('wait_ms', 2500)), 15000)
    cdp = CDP(page['webSocketDebuggerUrl'])
    try:
        cdp.send('Runtime.enable')
        cdp.send('Log.enable')
        return cdp.collect_events(wait_ms / 1000)
    finally:
        cdp.close()


def tool_screenshot(arguments):
    page = pick_page(arguments.get('tab_id'))
    cdp = CDP(page['webSocketDebuggerUrl'])
    try:
        result = cdp.send('Page.captureScreenshot', {'format': 'png'})
        data = result.get('result', {}).get('data', '')
        if not data:
            raise RuntimeError('screenshot failed')
        return {'mime': 'image/png', 'base64': data}
    finally:
        cdp.close()


HANDLERS = {
    'chrome_status': lambda arguments: tool_status(),
    'chrome_tabs': lambda arguments: tool_tabs(),
    'chrome_navigate': tool_navigate,
    'chrome_eval': tool_eval,
    'chrome_console': tool_console,
    'chrome_screenshot': tool_screenshot,
}


def send(message):
    sys.stdout.write(json.dumps(message) + '\n')
    sys.stdout.flush()


def reply(message_id, result=None, error=None):
    message = {'jsonrpc': '2.0', 'id': message_id}
    if error is not None:
        message['error'] = error
    else:
        message['result'] = result
    send(message)


def content_text(text, is_error=False):
    return {'content': [{'type': 'text', 'text': text}], 'isError': is_error}


def handle(request):
    method = request.get('method')
    message_id = request.get('id')
    if method == 'initialize':
        reply(message_id, {
            'protocolVersion': request.get('params', {}).get('protocolVersion', '2024-11-05'),
            'capabilities': {'tools': {}},
            'serverInfo': {'name': SERVER_NAME, 'version': SERVER_VERSION},
        })
    elif method in ('notifications/initialized', 'notifications/cancelled'):
        return
    elif method == 'ping':
        reply(message_id, {})
    elif method == 'tools/list':
        reply(message_id, {'tools': TOOLS})
    elif method == 'tools/call':
        params = request.get('params', {})
        name = params.get('name')
        arguments = params.get('arguments') or {}
        handler = HANDLERS.get(name)
        if handler is None:
            reply(message_id, content_text(f'unknown tool {name!r}', is_error=True))
            return
        if not enabled():
            reply(message_id, content_text(
                'Chrome agent access is disabled. Enable "Agent Chrome access" in KySettings '
                'to allow debugging.', is_error=True))
            return
        try:
            result = handler(arguments)
        except Exception as error:
            log(f'{name} failed: {error}')
            reply(message_id, content_text(f'{name} failed: {error}', is_error=True))
            return
        if isinstance(result, dict) and 'base64' in result and 'mime' in result:
            reply(message_id, {'content': [
                {'type': 'text', 'text': f'screenshot ({result["mime"]})'},
                {'type': 'image', 'data': result['base64'], 'mimeType': result['mime']},
            ]})
        else:
            reply(message_id, content_text(json.dumps(result, indent=2, default=str)))
    else:
        reply(message_id, error={'code': -32601, 'message': f'method not found: {method}'})


def main():
    log(f'started; enabled={enabled()} port={PORT}')
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError:
            log(f'bad json: {line[:200]}')
            continue
        try:
            handle(request)
        except Exception as error:
            log(f'handler crash: {error}')
            if 'id' in request:
                reply(request['id'], error={'code': -32603, 'message': str(error)})


if __name__ == '__main__':
    main()
