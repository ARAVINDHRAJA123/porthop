Shared test cases run by both editions, so the Mac (Swift) and Windows (JavaScript) code can't quietly drift apart:

- `ask.json` — Ask PortHop requests and what they should open (`Tests/EngineTests.swift` and `windows/test/golden.js`).
- `patterns.json` — custom folder patterns and the folder each should give.

Dates are local calendar days. Add a case here and both test suites pick it up.
