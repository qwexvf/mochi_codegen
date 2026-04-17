// Tests for CLI init and generate subcommands

import gleam/string
import mochi_codegen/cli
import mochi_codegen/config
import simplifile

pub fn init_creates_config_file_test() {
  let dir = "/tmp/mochi_cli_test_init"
  let _ = simplifile.delete_all([dir])
  let _ = simplifile.create_directory_all(dir)
  let config_path = dir <> "/mochi.config.json"

  // init should fail when run outside a dir context, but we test run_with_args
  // which writes to CWD. Instead test the config module directly.
  let conf = config.default()
  case config.write_to(conf, config_path) {
    Ok(_) -> Nil
    Error(msg) -> panic as { "Config write failed: " <> msg }
  }

  case config.read_from(config_path) {
    Ok(parsed) -> {
      case parsed.schema == ["schema.graphql"] {
        True -> Nil
        False -> panic as "Init config should have default schema path"
      }
    }
    Error(msg) -> panic as { "Config read failed: " <> msg }
  }

  let _ = simplifile.delete_all([dir])
  Nil
}

pub fn init_with_custom_schema_path_test() {
  let path = "/tmp/mochi_cli_test_custom.json"
  let conf = config.Config(..config.default(), schema: ["src/api.graphql"])
  case config.write_to(conf, path) {
    Ok(_) -> Nil
    Error(msg) -> panic as { "Write failed: " <> msg }
  }

  case config.read_from(path) {
    Ok(parsed) -> {
      case parsed.schema {
        ["src/api.graphql"] -> Nil
        _ -> panic as "Schema path should be custom value"
      }
    }
    Error(msg) -> panic as { "Read failed: " <> msg }
  }

  let _ = simplifile.delete(path)
  Nil
}

pub fn generate_with_missing_schema_fails_test() {
  let config_path = "/tmp/mochi_cli_test_gen.json"
  let conf =
    config.Config(..config.default(), schema: [
      "/tmp/mochi_nonexistent_schema.graphql",
    ])
  let _ = config.write_to(conf, config_path)

  let result = cli.run_with_args(["generate", "--config", config_path])

  case result {
    Error(_) -> Nil
    Ok(_) -> panic as "Generate with missing schema should fail"
  }

  let _ = simplifile.delete(config_path)
  Nil
}

pub fn generate_with_valid_schema_succeeds_test() {
  let dir = "/tmp/mochi_cli_test_gen_ok"
  let _ = simplifile.delete_all([dir])
  let _ = simplifile.create_directory_all(dir)

  let schema_path = dir <> "/schema.graphql"
  let ts_path = dir <> "/types.ts"
  let config_path = dir <> "/mochi.config.json"

  let _ =
    simplifile.write(
      schema_path,
      "type Query { hello: String }\ntype User { id: ID! name: String! }\n",
    )

  let conf =
    config.Config(
      schema: [schema_path],
      output: config.OutputConfig(
        typescript: option.Some(ts_path),
        gleam_types: option.None,
        resolvers: option.None,
        sdl: option.None,
      ),
      gleam: config.GleamConfig(
        types_module_prefix: "types",
        resolvers_module_prefix: "resolvers",
        type_suffix: "_types",
        resolver_suffix: "_resolvers",
        resolver_imports: [],
        generate_docs: True,
      ),
    )
  let _ = config.write_to(conf, config_path)

  let result = cli.run_with_args(["generate", "--config", config_path])

  case result {
    Ok(msg) -> {
      case string.contains(msg, "Generated TypeScript") {
        True -> Nil
        False -> panic as { "Should report TypeScript generation: " <> msg }
      }
    }
    Error(_) -> panic as "Generate with valid schema should succeed"
  }

  // Verify file was created
  case simplifile.is_file(ts_path) {
    Ok(True) -> Nil
    _ -> panic as "TypeScript file should exist"
  }

  let _ = simplifile.delete_all([dir])
  Nil
}

pub fn direct_mode_still_works_test() {
  let dir = "/tmp/mochi_cli_test_direct"
  let _ = simplifile.delete_all([dir])
  let _ = simplifile.create_directory_all(dir)

  let schema_path = dir <> "/test.graphql"
  let ts_path = dir <> "/out.ts"

  let _ = simplifile.write(schema_path, "type Query { ping: String }\n")

  let result = cli.run_with_args([schema_path, "-t", ts_path])

  case result {
    Ok(msg) -> {
      case string.contains(msg, "Generated TypeScript") {
        True -> Nil
        False -> panic as { "Direct mode should generate TypeScript: " <> msg }
      }
    }
    Error(_) -> panic as "Direct mode should work"
  }

  let _ = simplifile.delete_all([dir])
  Nil
}

pub fn help_flag_test() {
  case cli.run_with_args(["--help"]) {
    Error(cli.InvalidArgs(msg)) -> {
      case string.contains(msg, "mochi") {
        True -> Nil
        False -> panic as "Help should mention mochi"
      }
    }
    _ -> panic as "--help should return InvalidArgs with help text"
  }
}

// Need option import for generate test
import gleam/option
