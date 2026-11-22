## Stand-ins for the application code that the README snippets call
## (`fetchPayment`, `fetchOrders`, ...), so the snippets compile as written.

type
  Order* = object
    id*: int
  HttpError* = object of CatchableError
    status*: int

proc fetchPayment*(): string = "payment"
proc fetchOrders*(): seq[Order] = @[Order(id: 1)]
proc cachedOrders*(): seq[Order] = @[]
proc sendInvoice*() = discard
proc compute*(): int = 42
