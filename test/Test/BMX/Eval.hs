{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Test.BMX.Eval where

import           Control.Monad.Identity (Identity)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as T (toStrict)
import           Test.QuickCheck
import qualified Text.Blaze.Html as B
import qualified Text.Blaze.Html.Renderer.Text as B

import           BMX
import           BMX.Internal

import           Test.BMX.Arbitrary

import           P

rendersTo :: Text -> BMXState Identity -> Either Text Text
rendersTo input st = bimap renderBMXError renderPage
  $ templateFromText input >>= renderTemplate st

escapeText = T.toStrict . B.renderHtml . B.toHtml

tshow = T.pack . show
mustache t = "{{" <> t <> "}}"
single n v = defaultState `usingContext` contextFromList [(n, v)]

vacuousHelper, vacuousBlockHelper :: Monad m => Helper m
vacuousHelper = helper $ return UndefinedV
vacuousBlockHelper = blockHelper $ \_ _ -> return mempty
vacuousPartial :: Monad m => Partial m
vacuousPartial = partial $ return mempty
vacuousDecorator, vacuousBlockDecorator :: Monad m => Decorator m
vacuousDecorator = decorator $ \k -> liftBMX k
vacuousBlockDecorator = blockDecorator $ \_ k -> liftBMX k

-- -----------------------------------------------------------------------------
-- Public interface

-- shadowing a helper/partial/decorator should throw
prop_eval_shadow_helper = forAll simpleId $ \n ->
  isLeft (rendersTo mempty (mempty `usingHelpers` [(n, vacuousHelper)]
                                   `usingHelpers` [(n, vacuousBlockHelper)]))

prop_eval_shadow_partial = forAll simpleId $ \n ->
  isLeft (rendersTo mempty (mempty `usingPartials` [(n, mempty)]
                                   `usingPartials` [(n, mempty)]))

prop_eval_shadow_decorator = forAll simpleId $ \n ->
  isLeft (rendersTo mempty (mempty `usingDecorators` [(n, vacuousDecorator)]
                                   `usingDecorators` [(n, vacuousBlockDecorator)]))

-- -----------------------------------------------------------------------------
-- Mustache tests (no helpers)

-- any valid content should render to itself
prop_eval_content_id t = validContent t ==>
  rendersTo t mempty === pure t

-- any valid string invoked in a mustache should render to itself, escaped
prop_eval_mustache_string t = validString t ==> forAll simpleId $ \n ->
  rendersTo (mustache n) (single n (StringV t)) === pure (escapeText t)

-- same for unescaped mustache
prop_eval_mustache_string_unescaped t = validString t ==> forAll simpleId $ \n ->
  rendersTo ("{{{" <> n <> "}}}") (single n (StringV t)) === pure t

-- any valid number invoked in a mustache should render to itself
prop_eval_mustache_number i = forAll simpleId $ \n ->
  rendersTo (mustache n) (single n (IntV i)) === pure (tshow i)

-- both bools
prop_eval_mustache_bool_true = forAll simpleId $ \n ->
  rendersTo (mustache n) (single n (BoolV True)) === pure "true"

prop_eval_mustache_bool_false = forAll simpleId $ \n ->
  rendersTo (mustache n) (single n (BoolV False)) === pure "false"

-- should not be able to render undefined, null, context or list
prop_eval_mustache_null_fails = forAll simpleId $ \n ->
  isLeft (rendersTo (mustache n) (single n NullV))

prop_eval_mustache_undef_fails = forAll simpleId $ \n ->
  isLeft (rendersTo (mustache n) (single n UndefinedV))

prop_eval_mustache_context_fails ctx = forAll simpleId $ \n ->
  isLeft (rendersTo (mustache n) (single n (ContextV ctx)))

prop_eval_mustache_list_fails ls = forAll simpleId $ \n ->
  isLeft (rendersTo (mustache n) (single n (ListV ls)))

-- unknown variables in mustaches should throw errors
prop_eval_mustache_undefined_var_fails = forAll simpleId $ \n ->
  isLeft (rendersTo (mustache n) mempty)

-- comments should go away
prop_eval_comment_elim_1 t ctx = validComment t ==>
  rendersTo ("{{!--" <> t <> "--}}") (mempty `usingContext` ctx) === pure T.empty

prop_eval_comment_elim_2 t ctx = validWeakComment t ==>
  rendersTo ("{{!" <> t <> "}}") (mempty `usingContext` ctx) === pure T.empty

-- -----------------------------------------------------------------------------
-- Partials

-- should throw an error when using an undefined partial
prop_eval_partial_fails = forAll simpleId $ \n ->
  isLeft (rendersTo ("{{>" <> n <> "}}") mempty)

-- if block partial not found, should fail over to intermediate content
-- FIX replace content with a generated valid block when generator written
prop_eval_block_partial_failover t = validContent t ==> forAll simpleId $ \n ->
  rendersTo ("{{#>" <> n <> "}}" <> t <> "{{/" <> n <> "}}") mempty === pure t

-- -----------------------------------------------------------------------------
-- Decorators

-- define an inline partial containing some content, and immediately invoke it
prop_eval_inline_content t = validContent t ==> forAll simpleId $ \n ->
  rendersTo ("{{#* inline '" <> n <> "' }}" <> t <> "{{/inline}}{{>" <> n <> "}}") testContext === pure t

-- -----------------------------------------------------------------------------
-- Raw blocks
prop_eval_raw_block_id = forAll rawContent $ \t ->
  rendersTo ("{{{{noop}}}}" <> t <> "{{{{/noop}}}}") defaultState === pure t

-- -----------------------------------------------------------------------------
-- regression tests / units
-- FIX can turn these into properties once Context interface is nicer / have a good generator

prop_eval_unit_if = once $
  rendersTo "{{# if author }}{{author.name}}{{/if}}" testContext === pure "Yehuda Katz"

prop_eval_unit_if_else = once $
  rendersTo "{{# if garbage }}{{garbage}}{{else}}{{title}}{{/if}}" testContext
    === pure "My First Blog Post!"

prop_eval_unit_if_else_chain_1 = once $
  rendersTo
    "{{# if garbage }}{{garbage}}{{else if author}}{{author.id}}{{else}}{{title}}{{/if}}"
    testContext
    === pure "47"

prop_eval_unit_if_else_chain_2 = once $
  rendersTo
    "{{# if garbage }}{{garbage}}{{else if doctorb}}{{doctorb.id}}{{else}}{{title}}{{/if}}"
    testContext
    === pure "My First Blog Post!"

prop_Eval_unit_if_else_chain_3 = once $
  rendersTo
    "{{# if garbage }}{{garbage}}{{else if doctorb.id}}{{doctorb.id}}{{else}}{{title}}{{/if}}"
    testContext
    === pure "My First Blog Post!"

prop_eval_unit_each_ctx = once $
  rendersTo "{{# each author }}{{@index}} {{@key}}: {{this}} {{/each}}" testContext
    === pure "0 id: 47 1 name: Yehuda Katz "

prop_eval_unit_each_ctx_named = once $
  rendersTo "{{# each author as |key val|}}{{@index}} {{key}} {{val}} {{/each}}" testContext
    === pure "0 id 47 1 name Yehuda Katz "

prop_eval_unit_each_list = once $
  rendersTo "{{# each list }}{{@index}} {{this}} {{/each}}" testContext
    === pure "0 why 1 not? "

prop_eval_unit_each_list_named = once $
  rendersTo "{{# each list as |item idx|}}{{idx}} {{item}} {{/each}}" testContext
    === pure "0 why 1 not? "

prop_eval_unit_each_first_last = once $
  rendersTo "{{# each list }}{{#if @first}}first! {{/if}}{{#if @last}}last!{{/if}}{{/each}}" testContext
    === pure "first! last!"

-- singleton list should have both @first and @last set
prop_eval_unit_each_singleton = once $
  rendersTo "{{# each sing }}{{#if @first}}first! {{/if}}{{this}} {{#if @last}}last!{{/if}}{{/each}}" testContext
    === pure "first! lmnop last!"

-- lookup in current context
prop_eval_unit_lookup_1 = once $
  rendersTo "{{ lookup . 'title' }}" testContext === pure "My First Blog Post!"

-- lookup in another context
prop_eval_unit_lookup_2 = once $
  rendersTo "{{ lookup author 'name' }}" testContext === pure "Yehuda Katz"

-- regular partial
prop_eval_unit_partial = once $
  rendersTo "{{> mypartial }}"
  (testContext `usingPartials` [("mypartial", simplePartial)])
    === pure "They got those chewy pretzels"

-- partial with custom context
prop_eval_unit_partial_ctx = once $
  rendersTo "{{> authorid author }}"
  (testContext `usingPartials` [("authorid", testPartial')])
    === pure "The author's name is Yehuda Katz and their ID is 47"

-- partial with custom context and a hash
prop_eval_unit_partial_hash = once $
  rendersTo "{{> authorid author arg=500}}"
  (testContext `usingPartials` [("authorid", testPartial)])
    === pure "The author's name is Yehuda Katz and their ID is 47 arg = 500"

-- a dynamic partial with custom context and a hash
prop_eval_unit_partial_dynamic = once $
  rendersTo "{{> (lookup . 'component') author arg=555}}"
  (testContext `usingPartials` [("authorid", testPartial)])
    === pure "The author's name is Yehuda Katz and their ID is 47 arg = 555"

-- a partial invoked as partial block can access @partial-block special variable
prop_eval_unit_partial_block_data = once $
  rendersTo "{{#> mypartial }}{{title}}{{/mypartial}}"
  (testContext `usingPartials` [("mypartial", testPartialBlock)])
    === pure "block = My First Blog Post!"

-- Can look up item in list
prop_eval_unit_list_index_1 = once $
  rendersTo "{{ list.[0] }}" testContext === pure "why"

prop_eval_unit_list_index_2 = once $
  rendersTo "{{ list.[1] }}" testContext === pure "not?"

-- Bad index in list should crash
prop_eval_unit_list_index_bounds_1 = once $
  isLeft (rendersTo "{{ list.[-1] }}" testContext)

-- more bounds checking
prop_eval_unit_list_index_bounds_2 = once $
  isLeft (rendersTo "{{ list.[10] }}" testContext)

-- invalid number -> can't lookup in list
prop_eval_unit_list_index_notnum = once $
  isLeft (rendersTo "{{ list.[123abcde]}}" testContext)

-- make sure 'options' hash doesn't bleed into context for helpers, blockhelpers, rawblock, ...
-- (anything that isn't a partial)
prop_eval_unit_options_bleed_block = once . isLeft $
  rendersTo "{{#if title foo='bar' }}== {{body}} == {{ foo }} == {{/if}}" testContext

prop_eval_unit_options_bleed_helper = once . isLeft $
  rendersTo "{{ lookup . 'foo' foo='bar' }}" mempty


testContext :: BMXState Identity
testContext = defaultState `usingContext` (contextFromList [
    ("title", StringV "My First Blog Post!")
  , ("author", ContextV $ contextFromList [
                   ("id", IntV 47)
                 , ("name", StringV "Yehuda Katz")
                 ])
  , ("list", ListV [
                 StringV "why"
               , StringV "not?"
               ])
  , ("sing", ListV [StringV "lmnop"])
  , ("body", StringV "My first post. Wheeeee!")
  , ("html", StringV "<a href=\"google.com\">Cool Site</a>")
  , ("component", StringV "authorid")
  ])

testPartial =
  Template
    [ ContentStmt "The author's name is "
    , Mustache (Fmt Verbatim Verbatim) (SExp (PathL (PathID "name" Nothing)) [] (Hash []))
    , ContentStmt " and their ID is "
    , Mustache (Fmt Verbatim Verbatim) (SExp (PathL (PathID "id" Nothing)) [] (Hash []))
    , ContentStmt " arg = "
    , Mustache (Fmt Verbatim Verbatim) (SExp (PathL (PathID "arg" Nothing)) [] (Hash []))
    ]

testPartial' =
  Template
    [ ContentStmt "The author's name is "
    , Mustache (Fmt Verbatim Verbatim) (SExp (PathL (PathID "name" Nothing)) [] (Hash []))
    , ContentStmt " and their ID is "
    , Mustache (Fmt Verbatim Verbatim) (SExp (PathL (PathID "id" Nothing)) [] (Hash []))
    ]

simplePartial =
  Template
    [ ContentStmt "They got those chewy pretzels"
    ]

testPartialBlock =
  Template
    [ ContentStmt "block = "
    , PartialStmt (Fmt Verbatim Verbatim) (Lit (DataL (DataPath (PathID "partial-block" Nothing)))) Nothing (Hash [])
    ]

-- -----------------------------------------------------------------------------

return []
tests = $quickCheckAll