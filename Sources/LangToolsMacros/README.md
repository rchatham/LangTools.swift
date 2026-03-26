# LangToolsMacros

Schema generation helpers for LangTools structured output.

## SchemaBuilder

A fluent API for building JSON schemas:

```swift
var builder = SchemaBuilder()
_ = builder
    .title("WeatherCard")
    .string("location", description: "The location")
    .number("temperature")
    .string("unit", enumValues: ["celsius", "fahrenheit"])
let schema = builder.build()
```

## Manual Conformance

For full control, implement `StructuredOutput` manually:

```swift
struct WeatherCard: StructuredOutput {
    let location: String
    let temperature: Double

    static var jsonSchema: JSONSchema {
        .object(
            properties: [
                "location": .string(),
                "temperature": .number()
            ],
            required: ["location", "temperature"],
            additionalProperties: false
        )
    }
}
```

## Future: @StructuredOutput Macro

A macro implementation is planned that will automatically generate the `jsonSchema` property from struct definitions.
