// Tests for mochi_codegen/config.gleam

import gleam/option.{None, Some}
import gleam/string
import mochi_codegen/config
import simplifile

pub fn default_config_test() {
  let conf = config.default()
  case conf.schema {
    "schema.graphql" -> Nil
    _ -> panic as "Default schema should be schema.graphql"
  }
  case conf.output.typescript {
    Some(_) -> Nil
    None -> panic as "Default should include typescript output"
  }
  case conf.output.gleam_types {
    Some(_) -> Nil
    None -> panic as "Default should include gleam_types output"
  }
  case conf.output.resolvers {
    Some(_) -> Nil
    None -> panic as "Default should include resolvers output"
  }
  case conf.output.sdl {
    None -> Nil
    Some(_) -> panic as "Default should not include sdl output"
  }
  case conf.gleam.generate_docs {
    True -> Nil
    False -> panic as "Default should generate docs"
  }
}

pub fn to_json_produces_valid_json_test() {
  let json = config.to_json(config.default())

  // Should contain key fields
  case string.contains(json, "\"schema\"") {
    True -> Nil
    False -> panic as "JSON should contain schema key"
  }
  case string.contains(json, "\"output\"") {
    True -> Nil
    False -> panic as "JSON should contain output key"
  }
  case string.contains(json, "\"gleam\"") {
    True -> Nil
    False -> panic as "JSON should contain gleam key"
  }
  case string.contains(json, "\"types_module\"") {
    True -> Nil
    False -> panic as "JSON should contain types_module"
  }
}

pub fn roundtrip_default_config_test() {
  let original = config.default()
  let json = config.to_json(original)
  case config.from_json(json) {
    Ok(parsed) -> {
      case parsed.schema == original.schema {
        True -> Nil
        False -> panic as "Schema path should roundtrip"
      }
      case parsed.output.typescript == original.output.typescript {
        True -> Nil
        False -> panic as "Typescript output should roundtrip"
      }
      case parsed.output.sdl == original.output.sdl {
        True -> Nil
        False -> panic as "SDL output (None) should roundtrip"
      }
      case parsed.gleam.types_module == original.gleam.types_module {
        True -> Nil
        False -> panic as "types_module should roundtrip"
      }
      case parsed.gleam.generate_docs == original.gleam.generate_docs {
        True -> Nil
        False -> panic as "generate_docs should roundtrip"
      }
    }
    Error(msg) -> panic as { "Roundtrip failed: " <> msg }
  }
}

pub fn roundtrip_custom_config_test() {
  let conf =
    config.Config(
      schema: "src/api.graphql",
      output: config.OutputConfig(
        typescript: Some("out/types.ts"),
        gleam_types: None,
        resolvers: Some("out/resolvers.gleam"),
        sdl: Some("out/schema.graphql"),
      ),
      gleam: config.GleamConfig(
        types_module: "api_types",
        resolvers_module: "api_resolvers",
        generate_docs: False,
      ),
    )

  let json = config.to_json(conf)
  case config.from_json(json) {
    Ok(parsed) -> {
      case parsed.schema {
        "src/api.graphql" -> Nil
        _ -> panic as "Custom schema path should roundtrip"
      }
      case parsed.output.gleam_types {
        None -> Nil
        _ -> panic as "None gleam_types should roundtrip"
      }
      case parsed.output.sdl {
        Some("out/schema.graphql") -> Nil
        _ -> panic as "SDL output should roundtrip"
      }
      case parsed.gleam.generate_docs {
        False -> Nil
        True -> panic as "generate_docs=false should roundtrip"
      }
    }
    Error(msg) -> panic as { "Custom roundtrip failed: " <> msg }
  }
}

pub fn from_json_invalid_input_test() {
  case config.from_json("not json") {
    Error(_) -> Nil
    Ok(_) -> panic as "Invalid JSON should return error"
  }
}

pub fn from_json_missing_fields_test() {
  case config.from_json("{}") {
    Error(_) -> Nil
    Ok(_) -> panic as "Missing required fields should return error"
  }
}

pub fn write_and_read_config_test() {
  let path = "/tmp/mochi_test_config_" <> random_suffix() <> ".json"
  let conf = config.default()

  case config.write_to(conf, path) {
    Ok(_) -> Nil
    Error(msg) -> panic as { "Write failed: " <> msg }
  }

  case config.read_from(path) {
    Ok(parsed) -> {
      case parsed.schema == conf.schema {
        True -> Nil
        False -> panic as "Read config should match written config"
      }
    }
    Error(msg) -> panic as { "Read failed: " <> msg }
  }

  // Cleanup
  let _ = simplifile.delete(path)
  Nil
}

pub fn read_missing_file_test() {
  case config.read_from("/tmp/mochi_nonexistent_config.json") {
    Error(_) -> Nil
    Ok(_) -> panic as "Reading missing file should return error"
  }
}

pub fn to_json_omits_null_outputs_test() {
  let conf =
    config.Config(
      ..config.default(),
      output: config.OutputConfig(
        typescript: None,
        gleam_types: None,
        resolvers: None,
        sdl: None,
      ),
    )
  let json = config.to_json(conf)

  // None outputs should not appear as keys
  case string.contains(json, "\"typescript\"") {
    False -> Nil
    True -> panic as "None typescript should be omitted from JSON"
  }
}

@external(erlang, "erlang", "unique_integer")
fn unique_int() -> Int

fn random_suffix() -> String {
  let n = unique_int()
  case n < 0 {
    True -> string.inspect(-n)
    False -> string.inspect(n)
  }
}
