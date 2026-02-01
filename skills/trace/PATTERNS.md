# Flow Patterns Reference

Common patterns I can trace and diagram.

## Control Flow Patterns

### Conditional Chains (if/else)

```
function process(input)
├─ validate(input)
│  ├─ invalid → return error
│  └─ valid → continue
├─ transform(input)
└─ return result
```

### Switch Statements

```
handleAction(type)
├─ case 'CREATE' → createItem()
├─ case 'UPDATE' → updateItem()
├─ case 'DELETE' → deleteItem()
└─ default → throw UnknownAction
```

### Guard Clauses (Early Returns)

```
processUser(user)
├─ !user → return null (guard)
├─ !user.active → return null (guard)
├─ !hasPermission(user) → throw Forbidden (guard)
└─ doActualWork(user) → return result
```

## Loop Patterns

### For Loop with Break/Continue

```
findFirst(items, predicate)
├─ for each item:
│  ├─ skip if !predicate(item) → continue
│  └─ found → break, return item
└─ not found → return null
```

### Array Methods (map/filter/reduce)

```
processItems(items)
├─ filter(isValid)
│  └─ removes invalid items
├─ map(transform)
│  └─ transforms each item
└─ reduce(aggregate)
   └─ combines into result
```

## Async Patterns

### Promise Chain

```
fetchUser(id)
├─ fetch('/api/users/' + id)
├─ .then(response.json())
├─ .then(validateUser)
├─ .catch(handleError)
└─ return user or error
```

### Async/Await with Try/Catch

```
async loadData()
├─ try:
│  ├─ await fetchItems()
│  ├─ await processItems()
│  └─ return result
└─ catch:
   └─ logError, return fallback
```

### Promise.all (Parallel)

```
loadDashboard()
├─ Promise.all([
│  ├─ fetchUser() ──────┐
│  ├─ fetchStats() ─────┼─ parallel
│  └─ fetchNotifications()
├─ ])
└─ combine results
```

## Event-Driven Patterns

### Event Dispatch/Listen

```
Component A                    Component B
    │                              │
    ├─ dispatch('data-ready') ────►│
    │                              ├─ listener fires
    │                              ├─ process data
    │◄──── dispatch('processed') ──┤
    │                              │
```

### Callback Sequences

```
editor.on('change')
├─ debounce(150ms)
├─ validateChange()
├─ updateState()
└─ notifyParent()
```

### Custom Events (like tldraw)

```
Shape Drag
├─ onDragStart
│  └─ save initial position
├─ onDrag (repeated)
│  └─ update visual position
├─ onDragEnd
│  ├─ check drop target
│  ├─ dispatch 'module-nest' event
│  └─ update state
```

## State Patterns

### State Machine Transitions

```
Order State Machine
┌─────────┐    pay     ┌─────────┐
│ pending │ ─────────► │  paid   │
└─────────┘            └────┬────┘
                            │ ship
                       ┌────▼────┐
                       │ shipped │
                       └────┬────┘
                            │ deliver
                       ┌────▼─────┐
                       │ delivered│
                       └──────────┘
```

### Redux/Context Update Flow

```
User Action
├─ dispatch(action)
├─ reducer processes
│  ├─ validate action
│  └─ compute new state
├─ store updates
└─ components re-render
```

## Hierarchical Patterns

### Parent-Child Relationships

```
Container (parent)
├─ contains: [Child A, Child B]
├─ on child add:
│  ├─ update children array
│  ├─ recalculate bounds
│  └─ trigger re-render
└─ on child remove:
   ├─ remove from array
   ├─ recalculate bounds
   └─ trigger re-render
```

### Z-Order/Layering

```
Canvas Layers (bottom to top)
├─ Layer 0: Background shapes
├─ Layer 1: Regular shapes
├─ Layer 2: Selected shapes
└─ Layer 3: Dragging shape

On selection:
├─ remove from current layer
├─ add to selection layer
└─ visual: shape appears on top
```

### Nesting with Coordinate Systems

```
Page (0,0) ────────────────────┐
│                              │
│   Container (100, 100)       │
│   ┌──────────────────┐       │
│   │                  │       │
│   │  Child (20, 30)  │       │  ← local coords
│   │  ┌────────┐      │       │
│   │  │        │      │       │
│   │  └────────┘      │       │
│   │                  │       │
│   └──────────────────┘       │
│                              │
└──────────────────────────────┘

Child's page position = (100+20, 100+30) = (120, 130)
```

## Two-Step Sync Patterns

### Create Then Update

```
syncToCanvas(items)
├─ Step 1: Create/Update shapes
│  ├─ for each item:
│  │  ├─ exists? → updateShape()
│  │  └─ new? → createShape()
│  └─ shapes now exist but may be wrong parent
│
├─ Step 2: Reparent and position
│  ├─ for each item:
│  │  ├─ correct parent? → skip
│  │  └─ wrong parent? → reparentShape()
│  └─ shapes now in correct hierarchy
│
└─ Sync complete
```

### Optimistic Update + Reconcile

```
User makes change
├─ Update UI immediately (optimistic)
├─ Send to server async
│  ├─ success → keep UI state
│  └─ failure → rollback UI state
└─ Reconcile if server state differs
```
