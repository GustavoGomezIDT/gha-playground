// Tiny "POS cart" so there is something real to lint and test.

export function lineTotal(item) {
  return item.price * item.qty;
}

export function cartTotal(items, taxRate = 0) {
  const subtotal = items.reduce((sum, item) => sum + lineTotal(item), 0);
  return Math.round(subtotal * (1 + taxRate) * 100) / 100;
}
