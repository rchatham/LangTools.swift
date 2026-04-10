# LangToolsMacros

Macro support for LangTools structured output (pending full implementation).

## Current status

The `@StructuredOutput` macro is **planned but not yet implemented** — it requires
SwiftSyntax and a `CompilerPlugin` target. See `StructuredOutputMacro.swift` for
the full implementation roadmap.

## Available today (in the `LangTools` module)

### `JSONSchema.infer(from:)`

Automatically infers a `JSONSchema` from any `Decodable` type using decoder-driven
reflection — no annotations needed:

```swift
struct WeatherCard: StructuredOutput {
    let location: String
    let temperature: Double
    let unit: String

    static var jsonSchema: JSONSchema {
        JSONSchema.infer(from: Self.self)
    }
}
```

Supports: all primitive types, `Optional<T>`, `[T]`, nested structs, `Date`, `UUID`, `URL`, `Data`.

### `SchemaBuilder`

A fully chainable, immutable fluent API for manual schema construction:

```swift
let schema = SchemaBuilder()
    .title("WeatherCard")
    .string("location", description: "The location")
    .number("temperature")
    .string("unit", enumValues: ["celsius", "fahrenheit"])
    .build()
```

### Manual `StructuredOutput` conformance

For full control over the schema:

```swift
struct WeatherCard: StructuredOutput {
    let location: String
    let temperature: Double

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "location":    .string(description: "The location"),
                "temperature": .number(description: "The temperature value"),
            ],
            required: ["location", "temperature"],
            additionalProperties: false,
            title: "WeatherCard"
        )
    }
}
```

## Future: `@StructuredOutput` macro

When implemented, the macro will auto-generate the `jsonSchema` property:

```swift
@StructuredOutput
struct WeatherCard {
    let location: String
    let temperature: Double
}
// Expands to: StructuredOutput conformance with jsonSchema auto-generated
```
