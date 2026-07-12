# node-red-contrib-liquidstoolap

[Russian translation](README.ru.md)

Node-RED connector for Liquid Stoolap.

## Install

From the package directory during development:

```bash
npm pack
```

Install the generated tarball into your Node-RED user directory, then restart Node-RED.

## Nodes

- `liquid-stoolap-config`: shared connection configuration.
- `liquid-stoolap-sql`: executes SQL through `POST /sql`.

## SQL node contract

- SQL comes from configured `sql` field when set, otherwise from `msg.topic`.
- Params come from `msg.payload`.
- Per-message timeout may be supplied as `msg.liquidStoolap.timeoutMs`.
- Success goes to output 1 with server response in `msg.payload`.
- Error goes to output 2 with structured `msg.error`.

## Security

Bearer tokens are stored as Node-RED credentials on the configuration node. Do not hard-code tokens in flow function nodes.

## Test

```bash
npm test
npm run pack:check
```
