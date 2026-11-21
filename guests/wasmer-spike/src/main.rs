//! Spike guest for Wasmer journaling (results/wasmer-spike.md): a counter in a
//! local variable that sleeps between prints, so a periodic snapshot lands
//! mid-loop. No experiment-specific imports: Wasmer must capture it on its own.
fn main() {
    let mut sum: u64 = 0;
    for i in 1..=30u64 {
        sum += i;
        println!("spike i={i} sum={sum}");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    println!("spike done sum={sum} (expected 465)");
}
