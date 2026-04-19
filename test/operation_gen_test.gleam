import gleam/string
import gleeunit/should
import mochi/parser
import mochi/sdl_ast
import mochi/sdl_parser
import mochi_codegen/operation_gen

fn parse_ops(src: String) {
  let assert Ok(doc) = parser.parse(src)
  doc
}

fn parse_schema(src: String) -> sdl_ast.SDLDocument {
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
  out |> contains("Ok(#(user_id, target_id))") |> should.be_true
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
