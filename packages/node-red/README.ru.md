# node-red-contrib-liquidstoolap

[English version](README.md)

Node-RED connector для Liquid Stoolap.

## Установка

Из package directory во время разработки:

```bash
npm pack
```

Установите созданный tarball в Node-RED user directory, затем перезапустите Node-RED.

## Nodes

- `liquid-stoolap-config`: общая конфигурация подключения.
- `liquid-stoolap-sql`: выполняет SQL через `POST /sql`.

## Контракт SQL node

- SQL берётся из настроенного поля `sql`, если оно задано, иначе из `msg.topic`.
- Params берутся из `msg.payload`.
- Per-message timeout можно передать как `msg.liquidStoolap.timeoutMs`.
- Success идёт в output 1 с server response в `msg.payload`.
- Error идёт в output 2 со structured `msg.error`.

## Безопасность

Bearer tokens хранятся как Node-RED credentials на configuration node. Не прописывайте tokens в flow function nodes.

## Тесты

```bash
npm test
npm run pack:check
```
