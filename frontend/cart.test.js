import { test } from 'node:test';
import assert from 'node:assert/strict';
import { lineTotal, cartTotal } from './cart.js';

test('lineTotal multiplies price by qty', () => {
  assert.equal(lineTotal({ price: 2.5, qty: 4 }), 10);
});

test('cartTotal sums lines and applies tax', () => {
  const items = [
    { price: 1.99, qty: 2 },
    { price: 5, qty: 1 },
  ];
  assert.equal(cartTotal(items), 8.98);
  assert.equal(cartTotal(items, 0.08875), 9.78);
});
