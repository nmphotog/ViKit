import Foundation

// A small file to try ViKit on.
struct Greeter {
	let name: String

	func greet(times: Int) -> [String] {
		(1...times).map { i in "Hello, \(name)! (#\(i))" }
	}
}

let g = Greeter(name: "world")
for line in g.greet(times: 3) {
	print(line)
}
