use std::fmt::Display;

pub trait Shape<T> {
    const SIDES: usize;
    type Output;
    fn area(&self) -> T;
}

#[derive(Debug)]
pub struct MyStruct<T> {
    value: T,
}

pub enum Mode {
    Fast,
    Slow(u8),
}

impl Default for MyStruct<i32> {
    fn default() -> Self {
        Self { value: 0 }
    }
}

impl<T> Shape<T> for MyStruct<T>
where
    T: Copy + Display,
{
    const SIDES: usize = 4;
    type Output = T;

    fn area(&self) -> T {
        fn helper<U: Copy>(u: U) -> U {
            u
        }
        helper(self.value)
    }
}

impl<T: Clone> MyStruct<T> {
    pub fn new(value: T) -> Self {
        Self { value }
    }

    pub fn map<U, F>(self, f: F) -> MyStruct<U>
    where
        F: FnOnce(T) -> U,
    {
        MyStruct { value: f(self.value) }
    }
}

pub fn largest<T: PartialOrd + Copy>(items: &[T]) -> T {
    items[0]
}

mod inner {
    pub const LIMIT: u32 = 10;
}
