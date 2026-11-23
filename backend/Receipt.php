<?php

namespace Playground;

class Receipt
{
    /** @var array<int, array{name: string, price: float, qty: int}> */
    private $lines = [];

    public function add(string $name, float $price, int $qty = 1): void
    {
        $this->lines[] = ['name' => $name, 'price' => $price, 'qty' => $qty];
    }

    public function total(): float
    {
        $total = 0.0;
        foreach ($this->lines as $line) {
            $total += $line['price'] * $line['qty'];
        }

        return round($total, 2);
    }
}
