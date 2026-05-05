@target(erlang)
import gleam/option
import gleam/string
import gleeunit/should
import mochi_codegen/cli
import mochi_codegen/config
import simplifile

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

pub fn e2e_codegen_from_schema_and_operations_test() {
  let cwd = get_cwd()
  let tmp_dir = unique_tmp_dir("mochi_codegen_e2e")
  let gen_dir = tmp_dir <> "/src/generated/"

  let _ = simplifile.delete_all([tmp_dir])
  let assert Ok(_) =
    simplifile.create_directory_all(tmp_dir <> "/src/generated")

  let toml =
    "name = \"codegen_e2e\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0 and < 2.0.0\"\nmochi = { git = \"https://github.com/qwexvf/mochi\", ref = \"main\" }\n"
  let assert Ok(_) = simplifile.write(tmp_dir <> "/gleam.toml", toml)

  let schema_glob = cwd <> "/test/fixtures/e2e/graphql/*.graphql"
  let ops_glob = cwd <> "/test/fixtures/e2e/operations/*.gql"
  let conf =
    config.Config(
      schema: [schema_glob],
      operations_input: option.Some(ops_glob),
      output: config.OutputConfig(
        typescript: option.None,
        gleam_types: option.Some(gen_dir),
        resolvers: option.None,
        operations: option.Some(gen_dir),
        sdl: option.None,
      ),
      gleam: config.GleamConfig(
        types_module_prefix: "generated",
        resolvers_module_prefix: "generated",
        type_suffix: "_types",
        resolver_suffix: "_resolvers",
        resolver_imports: [],
        generate_docs: False,
      ),
    )

  let config_path = tmp_dir <> "/mochi.config.yaml"
  let assert Ok(_) = config.write_to(conf, config_path)

  case cli.run_with_args(["generate", "-c", config_path]) {
    Error(e) -> panic as { "Codegen failed: " <> string.inspect(e) }
    Ok(_) -> Nil
  }

  let types_path = gen_dir <> "schema_types.gleam"
  let queries_path = gen_dir <> "queries_resolvers.gleam"
  let mutations_path = gen_dir <> "mutations_resolvers.gleam"

  simplifile.is_file(types_path) |> should.equal(Ok(True))
  simplifile.is_file(queries_path) |> should.equal(Ok(True))
  simplifile.is_file(mutations_path) |> should.equal(Ok(True))

  // ── Types ──────────────────────────────────────────────────────────────────

  let assert Ok(types) = simplifile.read(types_path)

  // Object types
  types |> contains("pub type User") |> should.be_true
  types |> contains("pub type Post") |> should.be_true
  types |> contains("pub type Tag") |> should.be_true
  types |> contains("pub type PostConnection") |> should.be_true

  // Enums
  types |> contains("pub type UserRole") |> should.be_true
  types |> contains("pub type PostStatus") |> should.be_true
  types |> contains("pub type SortOrder") |> should.be_true

  // Custom scalars become type aliases
  types |> contains("pub type DateTime =") |> should.be_true
  types |> contains("pub type URL =") |> should.be_true

  // Fields use type aliases, not raw String
  types |> contains("created_at: DateTime") |> should.be_true
  types |> contains("avatar: Option(URL)") |> should.be_true

  // Nullable fields wrapped in Option
  types |> contains("published_at: Option(DateTime)") |> should.be_true

  // List fields
  types |> contains("tag_ids: List(String)") |> should.be_true

  // Input types with optional fields
  types |> contains("pub type CreateUserInput") |> should.be_true
  types |> contains("pub type UpdateUserInput") |> should.be_true
  types |> contains("pub type PostsFilterInput") |> should.be_true
  types |> contains("name: Option(String)") |> should.be_true
  types |> contains("sort_order: Option(SortOrder)") |> should.be_true

  // ── Queries ────────────────────────────────────────────────────────────────

  let assert Ok(queries) = simplifile.read(queries_path)

  // All query names
  queries |> contains("name: \"user\"") |> should.be_true
  queries |> contains("name: \"users\"") |> should.be_true
  queries |> contains("name: \"post\"") |> should.be_true
  queries |> contains("name: \"posts\"") |> should.be_true
  queries |> contains("name: \"tags\"") |> should.be_true
  queries |> contains("name: \"tagBySlug\"") |> should.be_true

  // Scalar arg helpers
  queries |> contains("query.get_id(args, \"id\")") |> should.be_true
  queries
  |> contains("query.get_optional_int(args, \"limit\")")
  |> should.be_true
  queries
  |> contains("query.get_optional_int(args, \"offset\")")
  |> should.be_true
  queries |> contains("query.get_string(args, \"slug\")") |> should.be_true

  // List return: users returns [User!]!
  queries |> contains("import gleam/list") |> should.be_true
  queries |> contains("list.map(items, user_to_dynamic)") |> should.be_true

  // Non-scalar singular return: post returns Post!
  queries |> contains("post_to_dynamic") |> should.be_true

  // List return: tags returns [Tag!]!
  queries |> contains("list.map(items, tag_to_dynamic)") |> should.be_true

  // Non-list non-scalar: posts returns PostConnection!
  queries |> contains("post_connection_to_dynamic") |> should.be_true

  // Input type arg: ListPosts filter (optional)
  queries |> contains("query.get_optional_dynamic(args, \"filter\")") |> should.be_true
  queries |> contains("decode.run") |> should.be_true

  // GetTags (no args) still uses query_with_args
  queries |> contains("query.query_with_args") |> should.be_true

  // Register: all 6 queries
  queries |> contains("pub fn register") |> should.be_true
  queries |> contains("add_query(user_query") |> should.be_true
  queries |> contains("add_query(users_query") |> should.be_true
  queries |> contains("add_query(post_query") |> should.be_true
  queries |> contains("add_query(posts_query") |> should.be_true
  queries |> contains("add_query(tags_query") |> should.be_true
  queries |> contains("add_query(tag_by_slug_query") |> should.be_true

  // ── Mutations ──────────────────────────────────────────────────────────────

  let assert Ok(mutations) = simplifile.read(mutations_path)

  // All mutation names
  mutations |> contains("name: \"createUser\"") |> should.be_true
  mutations |> contains("name: \"updateUser\"") |> should.be_true
  mutations |> contains("name: \"deleteUser\"") |> should.be_true
  mutations |> contains("name: \"createPost\"") |> should.be_true
  mutations |> contains("name: \"updatePost\"") |> should.be_true
  mutations |> contains("name: \"publishPost\"") |> should.be_true
  mutations |> contains("name: \"deletePost\"") |> should.be_true
  mutations |> contains("name: \"addTagToPost\"") |> should.be_true
  mutations |> contains("name: \"removeTagFromPost\"") |> should.be_true

  // CreateUserInput: all required fields decoded
  mutations |> contains("decode.field(\"name\"") |> should.be_true
  mutations |> contains("decode.field(\"email\"") |> should.be_true
  mutations |> contains("decode.field(\"role\"") |> should.be_true

  // UpdateUserInput: nullable fields use optional_field
  mutations |> contains("decode.optional_field(\"name\"") |> should.be_true
  mutations |> contains("decode.optional_field(\"email\"") |> should.be_true
  mutations |> contains("import gleam/option.{None}") |> should.be_true

  // UpdateUser: mixed ID arg + input arg
  mutations |> contains("query.get_id(args, \"id\")") |> should.be_true
  mutations |> contains("query.get_dynamic(args, \"input\")") |> should.be_true

  // AddTagToPost / RemoveTagFromPost: two ID args
  mutations
  |> contains("result.try(query.get_id(args, \"postId\"))")
  |> should.be_true
  mutations
  |> contains("result.try(query.get_id(args, \"tagId\"))")
  |> should.be_true

  // Boolean return: deleteUser, deletePost use scalar encoder
  mutations |> contains("fn(v) { types.to_dynamic(v) }") |> should.be_true

  // Non-scalar returns have named encoders
  mutations |> contains("user_to_dynamic") |> should.be_true
  mutations |> contains("post_to_dynamic") |> should.be_true

  // Register: all 9 mutations
  mutations |> contains("pub fn register") |> should.be_true
  mutations |> contains("add_mutation(create_user_mutation") |> should.be_true
  mutations |> contains("add_mutation(update_user_mutation") |> should.be_true
  mutations |> contains("add_mutation(delete_user_mutation") |> should.be_true
  mutations |> contains("add_mutation(create_post_mutation") |> should.be_true
  mutations |> contains("add_mutation(update_post_mutation") |> should.be_true
  mutations |> contains("add_mutation(publish_post_mutation") |> should.be_true
  mutations |> contains("add_mutation(delete_post_mutation") |> should.be_true
  mutations
  |> contains("add_mutation(add_tag_to_post_mutation")
  |> should.be_true
  mutations
  |> contains("add_mutation(remove_tag_from_post_mutation")
  |> should.be_true

  // ── gleam check ────────────────────────────────────────────────────────────

  let check_out = run_command("cd '" <> tmp_dir <> "' && gleam check 2>&1")
  check_out |> contains("error:") |> should.be_false

  let _ = simplifile.delete_all([tmp_dir])
}

@external(erlang, "mochi_codegen_ffi", "get_cwd")
fn get_cwd() -> String

@external(erlang, "mochi_codegen_ffi", "run_command")
fn run_command(cmd: String) -> String

@external(erlang, "mochi_codegen_ffi", "unique_tmp_dir")
fn unique_tmp_dir(prefix: String) -> String
