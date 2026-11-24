export interface Shape<T extends number = number> {
  area(): T;
  readonly name: string;
}

export type Pair<K, V> = { key: K; value: V };

export class Box<T> implements Shape<number> {
  readonly name = "box";
  constructor(private value: T) {}
  area(): number {
    return 1;
  }
  map<U>(fn: (v: T) => U): Box<U> {
    return new Box(fn(this.value));
  }
}

export enum Color {
  Red,
  Green,
}

export function identity<T>(value: T): T {
  return value;
}

export const arrow = <T,>(v: T): T => v;
