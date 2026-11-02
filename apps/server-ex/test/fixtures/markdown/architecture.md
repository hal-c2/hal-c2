# Order pipeline

How an order travels from the till to the kitchen. See [the request lifecycle](02-request-lifecycle.md#retries) and `OrderRouter`.

## Components

| Component | Owner | Latency (p95) |
| :-------- | :---: | ------------: |
| Gateway   | edge  |         12 ms |
| Router    | core  |          4 ms |
| `Kitchen` | ops   |         30 ms |

### Routing

```ts
export function route(order: Order): Station {
  return order.items.some((item) => item.hot) ? "grill" : "cold";
}
```

```mermaid
flowchart LR
    Till[Till] -->|order| Gateway
    Gateway --> Router{Hot items?}
    Router -->|yes| Grill
    Router -->|no| Cold
```

### Handshake

```mermaid
sequenceDiagram
    participant T as Till
    participant G as Gateway
    T->>G: POST /orders
    G-->>T: 202 Accepted
    Note over T,G: retried on timeout
```

## States

```mermaid
stateDiagram-v2
    [*] --> Placed
    Placed --> Cooking
    Cooking --> Ready
    Ready --> [*]
```

- Placed orders wait at most **30 s**.
  - After that the till *warns* the cashier.
- Ready orders are ~~printed~~ shown on the screen.
