"""Synthetic stdin/stdout peer. No network, login, model or personal data."""
import json
import os
import sys
import time

mode = sys.argv[1]
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method is None:
        assert request.get('id') == 'permission-check'
        assert request['error']['code'] == -32601
        continue
    assert method in {'initialize', 'initialized', 'account/read', 'model/list', 'thread/start', 'turn/start'}
    if method == 'initialized':
        continue
    ident = request['id']
    if method == 'initialize':
        if mode == 'brokenpipe':
            os.close(0)
            print(json.dumps({'id': ident, 'result': {'userAgent': 'synthetic'}}), flush=True)
            time.sleep(10)
            continue
        if mode == 'closed': sys.exit(0)
        if mode == 'hang': time.sleep(10); continue
        if mode == 'malformed': print('not json', flush=True); continue
        if mode == 'oversized': print('x' * (2 * 1024 * 1024 + 1), flush=True); continue
        print(json.dumps({'id': ident + 100, 'result': {'ignored': True}}), flush=True)
        print(json.dumps({'id': 'permission-check', 'method': 'item/commandExecution/requestApproval', 'params': {}}), flush=True)
        reply = json.dumps({'id': ident, 'result': {'userAgent': 'synthetic'}})
        # Split a frame at a non-line boundary.
        sys.stdout.write(reply[:7]); sys.stdout.flush()
        time.sleep(0.01)
        print(reply[7:], flush=True)
    elif method == 'model/list':
        reply = {'id': ident, 'result': {'data': [{'model': 'synthetic-model', 'displayName': 'Synthetic', 'hidden': False, 'isDefault': True}], 'nextCursor': None}}
        print(json.dumps(reply), flush=True)
    elif method == 'thread/start':
        params = request['params']
        assert params['ephemeral'] is True and params['sandbox'] == 'read-only'
        assert params['approvalPolicy'] == 'never' and params['modelProvider'] == 'openai'
        print(json.dumps({'id': ident, 'result': {'thread': {'id': 'synthetic-thread'}}}), flush=True)
        if mode.startswith('backpressure-'):
            # Stop reading before the client submits a full allowed-size input.
            time.sleep(0.2 if mode == 'backpressure-drain' else 3)
    elif method == 'turn/start':
        assert request['params']['threadId'] == 'synthetic-thread'
        assert request['params']['input'][0]['text'] == ('x' * (128 * 1024) if mode.startswith('backpressure-') else 'synthetic input')
        def event(method, params): print(json.dumps({'method': method, 'params': params}), flush=True)
        event('item/completed', {'threadId': 'unrelated', 'item': {'type': 'agentMessage', 'id': 'wrong', 'text': 'MUST NOT APPEAR'}})
        event('item/completed', {'threadId': 'synthetic-thread', 'item': {'type': 'agentMessage', 'id': 'thinking', 'phase': 'commentary', 'text': 'NOT FINAL'}})
        item = {'type': 'agentMessage', 'id': 'answer', 'phase': 'final_answer', 'text': 'synthetic answer'}
        if mode == 'longresponse':
            item['text'] = 'x' * (900 * 1024)
            for offset in range(0, len(item['text']), 1024):
                event('item/agentMessage/delta', {'threadId': 'synthetic-thread', 'itemId': 'answer', 'delta': item['text'][offset:offset + 1024]})
        if mode == 'fragmented':
            # Multiple UTF-8 lines split inside both JSON and multi-byte text.
            payload = ''.join(json.dumps({'method': 'synthetic', 'params': {'text': '合成片段', 'n': i}}, ensure_ascii=False) + '\n' for i in range(300)).encode()
            for offset in range(0, len(payload), 11):
                os.write(1, payload[offset:offset + 11])
        event('item/completed', {'threadId': 'synthetic-thread', 'item': item})
        if mode == 'answerlimit':
            for i in range(3):
                event('item/completed', {'threadId': 'synthetic-thread', 'item': dict(item, id=str(i), text='x' * (800 * 1024))})
        if mode != 'turnhang':
            event('turn/completed', {'threadId': 'synthetic-thread', 'turn': {'id': 'turn', 'status': 'failed' if mode == 'turnfail' else 'completed', 'items': [item]}})
        # Completion deliberately precedes the turn/start response.
        print(json.dumps({'id': ident, 'result': {'turn': {'id': 'turn'}}}), flush=True)
    else:
        assert request['params'] == {'refreshToken': False}
        if mode == 'rpc': reply = {'id': ident, 'error': {'code': -32001, 'message': 'synthetic'}}
        elif mode == 'missing': reply = {'id': ident, 'result': {}}
        else:
            account = None if mode == 'signedout' else {'type': 'apiKey' if mode == 'api' else 'chatgpt'}
            reply = {'id': ident, 'result': {'account': account, 'requiresOpenaiAuth': True}}
        print(json.dumps(reply), flush=True)
