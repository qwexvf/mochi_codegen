import gleam/string
import gleeunit/should
import mochi/parser
import mochi/internal/sdl_ast
import mochi/internal/sdl_parser
import mochi_codegen/operation_gen

fn parse_ops(src: String) {
  let assert Ok(doc) = parser.parse(src)
  doc
}

fn parse_schema(src: String) -> sdl_ast.SdlDocument {
  let assert Ok(doc) = sdl_parser.parse_sdl(src)
  doc
}

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

pub fn single_scalar_query_generates_query_with_args_test() {
  let ops = parse_ops("query GetUser($id: ID!) { user(id: $id) { id } }")
  let schema =
    parse_schema("type Query { user(id: ID!): User } type User { id: ID! }")
  let out = operation_gen.generate(ops, schema)
  out |> contains("query.query_with_args") |> should.be_true
  out |> contains("name: \"user\"") |> should.be_true
  out |> contains("query.get_id(args, \"id\")") |> should.be_true
}

pub fn single_input_type_mutation_generates_input_decode_test() {
  let ops =
    parse_ops(
      "mutation CreatePost($input: PostInput!) { createPost(input: $input) { id } }",
    )
  let schema =
    parse_schema(
      "type Mutation { createPost(input: PostInput!): Post }
type Post { id: ID! }
input PostInput { title: String! body: String! }",
    )
  let out = operation_gen.generate(ops, schema)
  out |> contains("dict.get(args, \"input\")") |> should.be_true
  out |> contains("decode.run") |> should.be_true
  out |> contains("decode.field(\"title\"") |> should.be_true
}

pub fn multi_var_scalar_mutation_generates_result_try_test() {
  let ops =
    parse_ops(
      "mutation Follow($userId: ID!, $targetId: ID!) { follow(userId: $userId, targetId: $targetId) { id } }",
    )
  let schema =
    parse_schema(
      "type Mutation { follow(userId: ID!, targetId: ID!): User }
type User { id: ID! }",
    )
  let out = operation_gen.generate(ops, schema)
  out |> contains("import gleam/result") |> should.be_true
  out
  |> contains("result.try(query.get_id(args, \"userId\"))")
  |> should.be_true
  out
  |> contains("result.try(query.get_id(args, \"targetId\"))")
  |> should.be_true
}

pub fn multi_var_with_input_type_uses_decode_not_get_string_test() {
  let ops =
    parse_ops(
      "mutation CreatePost($userId: ID!, $input: PostInput!) { createPost(userId: $userId, input: $input) { id } }",
    )
  let schema =
    parse_schema(
      "type Mutation { createPost(userId: ID!, input: PostInput!): Post }
type Post { id: ID! }
input PostInput { title: String! body: String! }",
    )
  let out = operation_gen.generate(ops, schema)
  out |> contains("import gleam/result") |> should.be_true
  out
  |> contains("result.try(query.get_id(args, \"userId\"))")
  |> should.be_true
  out |> contains("dict.get(args, \"input\")") |> should.be_true
  out |> contains("decode.run") |> should.be_true
  out |> contains("get_string(args, \"input\")") |> should.be_false
}

pub fn list_return_generates_list_encoder_test() {
  let ops =
    parse_ops(
      "query ListUsers($limit: Int, $offset: Int) { users(limit: $limit, offset: $offset) { id } }",
    )
  let schema =
    parse_schema(
      "type Query { users(limit: Int, offset: Int): [User!]! }
type User { id: ID! }",
    )
  let out = operation_gen.generate(ops, schema)
  out |> contains("import gleam/list") |> should.be_true
  out |> contains("list.map(items, user_to_dynamic)") |> should.be_true
  out |> contains("query.get_optional_int(args, \"limit\")") |> should.be_true
  out |> contains("query.get_optional_int(args, \"offset\")") |> should.be_true
}

pub fn combined_ops_generate_register_function_test() {
  let ops =
    parse_ops(
      "query GetUser($id: ID!) { user(id: $id) { id } }
mutation CreateUser($input: CreateUserInput!) { createUser(input: $input) { id } }",
    )
  let schema =
    parse_schema(
      "type Query { user(id: ID!): User }
type Mutation { createUser(input: CreateUserInput!): User }
type User { id: ID! }
input CreateUserInput { name: String! email: String! }",
    )
  let out = operation_gen.generate(ops, schema)
  out |> contains("pub fn register") |> should.be_true
  out |> contains("add_query(user_query") |> should.be_true
  out |> contains("add_mutation(create_user_mutation") |> should.be_true
}

pub fn create_user_decodes_all_input_fields_test() {
  let ops =
    parse_ops(
      "mutation CreateUser($input: CreateUserInput!) { createUser(input: $input) { id } }",
    )
  let schema =
    parse_schema(
      "type Mutation { createUser(input: CreateUserInput!): User }
type User { id: ID! }
input CreateUserInput { name: String! email: String! }",
    )
  let out = operation_gen.generate(ops, schema)
  out |> contains("decode.field(\"name\"") |> should.be_true
  out |> contains("decode.string") |> should.be_true
  out |> contains("decode.field(\"email\"") |> should.be_true
}

pub fn boolean_return_uses_scalar_encoder_test() {
  let ops = parse_ops("mutation DeleteUser($id: ID!) { deleteUser(id: $id) }")
  let schema =
    parse_schema(
      "type Mutation { deleteUser(id: ID!): Boolean! }
type User { id: ID! }",
    )
  let out = operation_gen.generate(ops, schema)
  out |> contains("fn(v) { types.to_dynamic(v) }") |> should.be_true
  out |> contains("delete_user_to_dynamic") |> should.be_false
}

pub fn unknown_operation_field_reports_missing_test() {
  let ops = parse_ops("query Missing { doesNotExist { id } }")
  let schema =
    parse_schema("type Query { other: String } type User { id: ID! }")

  operation_gen.unknown_fields(ops, schema)
  |> should.equal(["doesNotExist"])

  let out = operation_gen.generate(ops, schema)
  // Sentinel marker identifies the field that's missing from the schema.
  out |> contains("<MISSING:doesNotExist>") |> should.be_true
  // Old generic "TODO" marker is gone.
  out |> contains("schema.Named(\"TODO\")") |> should.be_false
}

pub fn known_operation_field_has_no_unknowns_test() {
  let ops = parse_ops("query GetUser($id: ID!) { user(id: $id) { id } }")
  let schema =
    parse_schema("type Query { user(id: ID!): User } type User { id: ID! }")

  operation_gen.unknown_fields(ops, schema) |> should.equal([])
}
