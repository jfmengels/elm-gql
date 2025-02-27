module GraphQL.Engine exposing
    ( batch
    , nullable, list, object, objectWith, decode
    , enum, maybeEnum
    , field, fieldWith
    , union
    , Selection, select, with, map, map2, recover
    , arg, argList, Optional, optional
    , Query, query, Mutation, mutation, Error(..)
    , prebakedQuery, Premade, premadeOperation
    , queryString
    , Argument(..), maybeScalarEncode
    , encodeOptionals, encodeOptionalsAsJson, encodeInputObject, encodeArgument
    , decodeNullable, getGql, mapPremade
    , unsafe, selectTypeNameButSkip
    , Request, toRequest, send, simulate, mapRequest
    , Option(..), InputObject, inputObject, addField, addOptionalField, encodeInputObjectAsJson, inputObjectToFieldList
    , jsonField, andMap
    , bakeToSelection
    )

{-|

@docs batch

@docs nullable, list, object, objectWith, decode

@docs enum, maybeEnum

@docs field, fieldWith

@docs union

@docs Selection, select, with, map, map2, recover

@docs arg, argList, Optional, optional

@docs Query, query, Mutation, mutation, Error

@docs prebakedQuery, Premade, premadeOperation

@docs queryString

@docs Argument, maybeScalarEncode

@docs encodeOptionals, encodeOptionalsAsJson, encodeInputObject, encodeArgument

@docs decodeNullable, getGql, mapPremade

@docs unsafe, selectTypeNameButSkip

@docs Request, toRequest, send, simulate, mapRequest

@docs Option, InputObject, inputObject, addField, addOptionalField, encodeInputObjectAsJson, inputObjectToFieldList

@docs jsonField, andMap

-}

import Dict exposing (Dict)
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Set


{-| Batch a number of selection sets together!
-}
batch : List (Selection source data) -> Selection source (List data)
batch selections =
    Selection <|
        Details
            (\context ->
                List.foldl
                    (\(Selection (Details toFieldsGql _)) ( ctxt, fields ) ->
                        let
                            ( newCtxt, newFields ) =
                                toFieldsGql ctxt
                        in
                        ( newCtxt
                        , fields ++ newFields
                        )
                    )
                    ( context, [] )
                    selections
            )
            (\context ->
                List.foldl
                    (\(Selection (Details _ toItemDecoder)) ( ctxt, cursorFieldsDecoder ) ->
                        let
                            ( newCtxt, itemDecoder ) =
                                toItemDecoder ctxt
                        in
                        ( newCtxt
                        , cursorFieldsDecoder
                            |> Decode.andThen
                                (\existingList ->
                                    Decode.map
                                        (\item ->
                                            item :: existingList
                                        )
                                        itemDecoder
                                )
                        )
                    )
                    ( context, Decode.succeed [] )
                    selections
            )


{-| -}
recover : recovered -> (data -> recovered) -> Selection source data -> Selection source recovered
recover default wrapValue (Selection (Details toQuery toDecoder)) =
    Selection
        (Details toQuery
            (\context ->
                let
                    ( newContext, decoder ) =
                        toDecoder context
                in
                ( newContext
                , Decode.oneOf
                    [ Decode.map wrapValue decoder
                    , Decode.succeed default
                    ]
                )
            )
        )


{-| -}
union : List ( String, Selection source data ) -> Selection source data
union options =
    Selection <|
        Details
            (\context ->
                let
                    ( fragments, fragmentContext ) =
                        List.foldl
                            (\( name, Selection (Details fragQuery _) ) ( frags, currentContext ) ->
                                let
                                    ( newContext, fields ) =
                                        fragQuery currentContext

                                    nonEmptyFields =
                                        case fields of
                                            [] ->
                                                -- we're already selecting typename at the root.
                                                -- this is just so we don't have an empty set of brackets
                                                [ Field "__typename" Nothing [] [] ]

                                            _ ->
                                                fields
                                in
                                ( Fragment name nonEmptyFields :: frags
                                , newContext
                                )
                            )
                            ( [], context )
                            options
                in
                ( fragmentContext
                , Field "__typename" Nothing [] [] :: fragments
                )
            )
            (\context ->
                let
                    ( fragmentDecoders, fragmentContext ) =
                        List.foldl
                            (\( name, Selection (Details _ toFragDecoder) ) ( frags, currentContext ) ->
                                let
                                    ( newContext, fragDecoder ) =
                                        toFragDecoder currentContext

                                    fragDecoderWithTypename =
                                        Decode.field "__typename" Decode.string
                                            |> Decode.andThen
                                                (\typename ->
                                                    if typename == name then
                                                        fragDecoder

                                                    else
                                                        Decode.fail "Unknown union variant"
                                                )
                                in
                                ( fragDecoderWithTypename :: frags
                                , newContext
                                )
                            )
                            ( [], context )
                            options
                in
                ( fragmentContext
                , Decode.oneOf fragmentDecoders
                )
            )


{-| -}
maybeEnum : List ( String, item ) -> Decode.Decoder (Maybe item)
maybeEnum options =
    Decode.oneOf
        [ Decode.map Just (enum options)
        , Decode.succeed Nothing
        ]


{-| -}
enum : List ( String, item ) -> Decode.Decoder item
enum options =
    Decode.string
        |> Decode.andThen
            (findFirstMatch options)


findFirstMatch : List ( String, item ) -> String -> Decode.Decoder item
findFirstMatch options str =
    case options of
        [] ->
            Decode.fail ("Unexpected enum value: " ++ str)

        ( name, value ) :: remaining ->
            if name == str then
                Decode.succeed value

            else
                findFirstMatch remaining str


{-| Used in generated code to handle maybes
-}
nullable : Selection source data -> Selection source (Maybe data)
nullable (Selection (Details toFieldsGql toFieldsDecoder)) =
    Selection <|
        Details
            toFieldsGql
            (\context ->
                let
                    ( fieldContext, fieldsDecoder ) =
                        toFieldsDecoder context
                in
                ( fieldContext
                , Decode.oneOf
                    [ Decode.map Just fieldsDecoder
                    , Decode.succeed Nothing
                    ]
                )
            )


{-| Used in generated code to handle maybes
-}
list : Selection source data -> Selection source (List data)
list (Selection (Details toFieldsGql toFieldsDecoder)) =
    Selection <|
        Details
            toFieldsGql
            (\context ->
                let
                    ( fieldContext, fieldsDecoder ) =
                        toFieldsDecoder context
                in
                ( fieldContext
                , Decode.list fieldsDecoder
                )
            )


{-| -}
object : String -> Selection source data -> Selection otherSource data
object =
    objectWith (inputObject "NoArgs")


type Variable
    = Variable String


{-| -}
objectWith : InputObject args -> String -> Selection source data -> Selection otherSource data
objectWith inputObj name (Selection (Details toFieldsGql toFieldsDecoder)) =
    Selection <|
        Details
            (\context ->
                let
                    ( fieldContext, fields ) =
                        toFieldsGql { context | aliases = Dict.empty }

                    new =
                        applyContext inputObj name { fieldContext | aliases = context.aliases }
                in
                ( new.context
                , [ Field name new.aliasString new.args fields
                  ]
                )
            )
            (\context ->
                let
                    ( fieldContext, fieldsDecoder ) =
                        toFieldsDecoder { context | aliases = Dict.empty }

                    new =
                        applyContext inputObj name { fieldContext | aliases = context.aliases }

                    aliasedName =
                        Maybe.withDefault name new.aliasString
                in
                ( new.context
                , Decode.field aliasedName fieldsDecoder
                )
            )


{-| This adds a bare decoder for data that has already been pulled down.

Note, this is rarely needed! So far, only when a query or mutation returns a scalar directly without selecting any fields.

-}
decode : Decode.Decoder data -> Selection source data
decode decoder =
    Selection <|
        Details
            (\context ->
                ( context
                , []
                )
            )
            (\context ->
                ( context
                , decoder
                )
            )


{-| -}
selectTypeNameButSkip : Selection source ()
selectTypeNameButSkip =
    Selection <|
        Details
            (\context ->
                ( context
                , [ Field "__typename" Nothing [] []
                  ]
                )
            )
            (\context ->
                ( context
                , Decode.succeed ()
                )
            )


{-| -}
field : String -> String -> Decode.Decoder data -> Selection source data
field name gqlTypeName decoder =
    fieldWith (inputObject gqlTypeName) name gqlTypeName decoder


{-| -}
fieldWith : InputObject args -> String -> String -> Decode.Decoder data -> Selection source data
fieldWith args name gqlType decoder =
    Selection <|
        Details
            (\context ->
                let
                    new =
                        applyContext args name context
                in
                ( new.context
                , [ Field name new.aliasString new.args []
                  ]
                )
            )
            (\context ->
                let
                    new =
                        applyContext args name context

                    aliasedName =
                        Maybe.withDefault name new.aliasString
                in
                ( new.context
                , Decode.field aliasedName decoder
                )
            )


applyContext :
    InputObject args
    -> String
    -> Context
    ->
        { context : Context
        , aliasString : Maybe String
        , args : List ( String, Variable )
        }
applyContext args name context =
    let
        ( maybeAlias, newAliases ) =
            makeAlias name context.aliases

        ( vars, newVariables ) =
            captureArgs args context.variables
    in
    { context =
        { aliases = newAliases
        , variables = newVariables
        }
    , aliasString = maybeAlias
    , args = vars
    }


{-| This is the piece of code that's responsible for swapping real argument values (i.e. json values)

with variables.

-}
captureArgs :
    InputObject args
    -> Dict String VariableDetails
    ->
        ( List ( String, Variable )
        , Dict String VariableDetails
        )
captureArgs (InputObject objname args) context =
    case args of
        [] ->
            ( [], context )

        _ ->
            captureArgsHelper args context []


{-| -}
captureArgsHelper :
    List ( String, VariableDetails )
    -> Dict String VariableDetails
    -> List ( String, Variable )
    ->
        ( List ( String, Variable )
        , Dict String VariableDetails
        )
captureArgsHelper args context alreadyPassed =
    case args of
        [] ->
            ( alreadyPassed, context )

        ( name, value ) :: remaining ->
            let
                varname =
                    getValidVariableName name 0 context

                newContext =
                    Dict.insert varname value context
            in
            captureArgsHelper remaining
                newContext
                (( name, Variable varname ) :: alreadyPassed)


getValidVariableName : String -> Int -> Dict String val -> String
getValidVariableName str index used =
    let
        attemptedName =
            if index == 0 then
                str

            else
                str ++ String.fromInt index
    in
    if Dict.member attemptedName used then
        getValidVariableName str (index + 1) used

    else
        attemptedName


makeAlias : String -> Dict String Int -> ( Maybe String, Dict String Int )
makeAlias name aliases =
    case Dict.get name aliases of
        Nothing ->
            ( Nothing, Dict.insert name 0 aliases )

        Just found ->
            ( Just (name ++ String.fromInt (found + 1))
            , Dict.insert name (found + 1) aliases
            )


{-| -}
type Selection source selected
    = Selection (Details selected)


type alias Context =
    { aliases : Dict String Int
    , variables : Dict String VariableDetails
    }


type alias VariableDetails =
    { gqlTypeName : String
    , value : Encode.Value
    }


{-| -}
unsafe : Selection source selected -> Selection unsafe selected
unsafe (Selection deets) =
    Selection deets


type Free
    = Free


toFree : Argument thing -> Argument Free
toFree argument =
    case argument of
        ArgValue json tag ->
            ArgValue json tag

        Var varname ->
            Var varname


empty : Context
empty =
    { aliases = Dict.empty
    , variables = Dict.empty
    }


{-| An unguarded GQL query.
-}
type Details selected
    = Details
        -- This is an optional *operation name*
        -- Can only be set on Queries and Mutations
        (Maybe String)
        -- Both of these take a Set String, which is how we're keeping track of
        -- what needs to be aliased
        -- How to make the gql query
        (Context -> ( Context, List Field ))
        -- How to decode the data coming back
        (Context -> ( Context, Decode.Decoder selected ))


type Field
    = --    name   alias          args                        children
      Field String (Maybe String) (List ( String, Variable )) (List Field)
      --        ...on FragmentName
    | Fragment String (List Field)
      -- a piece of GQL that has been validated separately
      -- This is generally for operational gql
    | Baked String


{-| We can also accept:

  - Enum values (unquoted)
  - custom scalars

But we can define anything else in terms of these:

-}
type Argument obj
    = ArgValue Encode.Value String
    | Var String


{-| -}
type Option value
    = Present value
    | Null
    | Absent


{-| -}
type InputObject value
    = InputObject String (List ( String, VariableDetails ))


{-| -}
inputObject : String -> InputObject value
inputObject name =
    InputObject name []


{-| -}
addField : String -> String -> Encode.Value -> InputObject value -> InputObject value
addField fieldName gqlFieldType val (InputObject name inputFields) =
    InputObject name
        (( fieldName
         , { gqlTypeName = gqlFieldType
           , value = val
           }
         )
            :: inputFields
        )


{-| -}
addOptionalField : String -> String -> Option value -> (value -> Encode.Value) -> InputObject input -> InputObject input
addOptionalField fieldName gqlFieldType optionalValue toJsonValue (InputObject name inputFields) =
    InputObject name
        (case optionalValue of
            Absent ->
                inputFields

            Null ->
                ( fieldName, { value = Encode.null, gqlTypeName = gqlFieldType } ) :: inputFields

            Present val ->
                ( fieldName, { value = toJsonValue val, gqlTypeName = gqlFieldType } ) :: inputFields
        )


{-| -}
type Optional arg
    = Optional String (Argument arg)


{-| The encoded value and the name of the expected type for this argument
-}
arg : Encode.Value -> String -> Argument obj
arg val typename =
    ArgValue val typename


{-| -}
argList : List (Argument obj) -> String -> Argument input
argList fields typeName =
    ArgValue
        (fields
            |> Encode.list
                (\argVal ->
                    case argVal of
                        ArgValue val _ ->
                            val

                        Var varName ->
                            Encode.string varName
                )
        )
        typeName


{-| -}
inputObjectToFieldList : InputObject a -> List ( String, VariableDetails )
inputObjectToFieldList (InputObject _ fields) =
    fields


{-| -}
encodeInputObjectAsJson : InputObject value -> Decode.Value
encodeInputObjectAsJson (InputObject _ fields) =
    Encode.object (List.map (\( fieldName, details ) -> ( fieldName, details.value )) fields)


{-| -}
encodeInputObject : List ( String, Argument obj ) -> String -> Argument input
encodeInputObject fields typeName =
    ArgValue
        (fields
            |> List.map
                (\( name, argVal ) ->
                    case argVal of
                        ArgValue val _ ->
                            ( name, val )

                        Var varName ->
                            ( name, Encode.string varName )
                )
            |> Encode.object
        )
        typeName


{-| -}
encodeArgument : Argument obj -> Encode.Value
encodeArgument argVal =
    case argVal of
        ArgValue val _ ->
            val

        Var varName ->
            Encode.string varName


{-| -}
encodeOptionals : List (Optional arg) -> List ( String, Argument arg )
encodeOptionals opts =
    List.foldl
        (\(Optional optName argument) (( found, gathered ) as skip) ->
            if Set.member optName found then
                skip

            else
                ( Set.insert optName found
                , ( optName, argument ) :: gathered
                )
        )
        ( Set.empty, [] )
        opts
        |> Tuple.second


{-| -}
encodeOptionalsAsJson : List (Optional arg) -> List ( String, Encode.Value )
encodeOptionalsAsJson opts =
    List.foldl
        (\(Optional optName argument) (( found, gathered ) as skip) ->
            if Set.member optName found then
                skip

            else
                ( Set.insert optName found
                , ( optName, argument ) :: gathered
                )
        )
        ( Set.empty, [] )
        opts
        |> Tuple.second
        |> List.map (Tuple.mapSecond encodeArgument)


{-|

    Encode the nullability in the argument itself.

-}
optional : String -> Argument arg -> Optional arg
optional =
    Optional


{-| -}
select : data -> Selection source data
select data =
    Selection
        (Details Nothing
            (\context ->
                ( context, [] )
            )
            (\context ->
                ( context, Decode.succeed data )
            )
        )


{-| -}
with : Selection source a -> Selection source (a -> b) -> Selection source b
with =
    map2 (|>)


{-| -}
map : (a -> b) -> Selection source a -> Selection source b
map fn (Selection (Details maybeOpName fields decoder)) =
    Selection <|
        Details maybeOpName
            fields
            (\aliases ->
                let
                    ( newAliases, newDecoder ) =
                        decoder aliases
                in
                ( newAliases, Decode.map fn newDecoder )
            )


mergeOpNames : Maybe String -> Maybe String -> Maybe String
mergeOpNames maybeOne maybeTwo =
    case ( maybeOne, maybeTwo ) of
        ( Nothing, Nothing ) ->
            Nothing

        ( Just one, _ ) ->
            Just one

        _ ->
            two


{-| -}
map2 : (a -> b -> c) -> Selection source a -> Selection source b -> Selection source c
map2 fn (Selection (Details oneOpName oneFields oneDecoder)) (Selection (Details twoOpName twoFields twoDecoder)) =
    Selection <|
        Details
            (mergeOpNames oneOpName twoOpName)
            (\aliases ->
                let
                    ( oneAliasesNew, oneFieldsNew ) =
                        oneFields aliases

                    ( twoAliasesNew, twoFieldsNew ) =
                        twoFields oneAliasesNew
                in
                ( twoAliasesNew
                , oneFieldsNew ++ twoFieldsNew
                )
            )
            (\aliases ->
                let
                    ( oneAliasesNew, oneDecoderNew ) =
                        oneDecoder aliases

                    ( twoAliasesNew, twoDecoderNew ) =
                        twoDecoder oneAliasesNew
                in
                ( twoAliasesNew
                , Decode.map2 fn oneDecoderNew twoDecoderNew
                )
            )


{-| -}
bakeToSelection : Maybe String -> String -> List ( String, VariableDetails ) -> Decode.Decoder data -> Premade data
bakeToSelection maybeOpName gql args decoder =
    Selection
        (Details maybeOpName
            (\context ->
                ( { context
                    | variables =
                        args
                            |> Dict.fromList
                            |> Dict.union context.variables
                  }
                , [ Baked gql ]
                )
            )
            (\context ->
                ( { context
                    | variables =
                        args
                            |> Dict.fromList
                            |> Dict.union context.variables
                  }
                , decoder
                )
            )
        )


{-| -}
prebakedQuery : String -> List ( String, VariableDetails ) -> Decode.Decoder data -> Premade data
prebakedQuery gql args decoder =
    Premade
        { gql = gql
        , args = List.map (Tuple.mapSecond .value) args
        , decoder = decoder
        }



{- Making requests -}


{-| -}
type Premade data
    = Premade
        { gql : String
        , decoder : Decode.Decoder data
        , args : List ( String, Encode.Value )
        }


{-| -}
type Query
    = Query


{-| -}
type Mutation
    = Mutation


{-| -}
getGql : Premade data -> String
getGql (Premade { gql }) =
    gql


{-| -}
mapPremade : (a -> b) -> Premade a -> Premade b
mapPremade fn (Premade details) =
    Premade
        { gql = details.gql
        , decoder = Decode.map fn details.decoder
        , args = details.args
        }


{-| -}
premadeOperation :
    Premade value
    ->
        { headers : List Http.Header
        , url : String
        , timeout : Maybe Float
        , tracker : Maybe String
        }
    -> Cmd (Result Error value)
premadeOperation sel config =
    Http.request
        { method = "POST"
        , headers = config.headers
        , url = config.url
        , body = Http.jsonBody (bodyPremade sel)
        , expect = expectPremade sel
        , timeout = config.timeout
        , tracker = config.tracker
        }


{-| -}
type Request value
    = Request
        { method : String
        , headers : List ( String, String )
        , url : String
        , body : Encode.Value
        , expect : Http.Response String -> Result Error value
        , timeout : Maybe Float
        , tracker : Maybe String
        }


{-| -}
mapRequest : (a -> b) -> Request a -> Request b
mapRequest fn (Request request) =
    Request
        { method = request.method
        , headers = request.headers
        , url = request.url
        , body = request.body
        , expect = request.expect >> Result.map fn
        , timeout = request.timeout
        , tracker = request.tracker
        }


{-| Return details that can be directly given to `Http.request`.

This is so that wiring up [Elm Program Test](https://package.elm-lang.org/packages/avh4/elm-program-test/latest/ProgramTest) is relatively easy.

-}
toRequest :
    Premade value
    ->
        { headers : List ( String, String )
        , url : String
        , timeout : Maybe Float
        , tracker : Maybe String
        }
    -> Request value
toRequest sel config =
    Request
        { method = "POST"
        , headers = config.headers
        , url = config.url
        , body = bodyPremade sel
        , expect = decodePremade sel
        , timeout = config.timeout
        , tracker = config.tracker
        }


{-| -}
send : Request data -> Cmd (Result Error data)
send (Request req) =
    Http.request
        { method = req.method
        , headers = List.map (\( key, val ) -> Http.header key val) req.headers
        , url = req.url
        , body = Http.jsonBody req.body
        , expect =
            Http.expectStringResponse identity req.expect
        , timeout = req.timeout
        , tracker = req.tracker
        }


{-| -}
simulate :
    { toHeader : String -> String -> header
    , toExpectation : (Http.Response String -> Result Error value) -> expectation
    , toBody : Encode.Value -> body
    , toRequest :
        { method : String
        , headers : List header
        , url : String
        , body : body
        , expect : expectation
        , timeout : Maybe Float
        , tracker : Maybe String
        }
        -> simulated
    }
    -> Request value
    -> simulated
simulate config (Request req) =
    config.toRequest
        { method = req.method
        , headers = List.map (\( key, val ) -> config.toHeader key val) req.headers
        , url = req.url
        , body = config.toBody req.body
        , expect = config.toExpectation req.expect
        , timeout = req.timeout
        , tracker = req.tracker
        }


{-| -}
query :
    Selection Query value
    ->
        { name : Maybe String
        , headers : List Http.Header
        , url : String
        , timeout : Maybe Float
        , tracker : Maybe String
        }
    -> Cmd (Result Error value)
query sel config =
    Http.request
        { method = "POST"
        , headers = config.headers
        , url = config.url
        , body = body "query" config.name sel
        , expect = expect identity sel
        , timeout = config.timeout
        , tracker = config.tracker
        }


{-| -}
mutation :
    Selection Mutation msg
    ->
        { name : Maybe String
        , headers : List Http.Header
        , url : String
        , timeout : Maybe Float
        , tracker : Maybe String
        }
    -> Cmd (Result Error msg)
mutation sel config =
    Http.request
        { method = "POST"
        , headers = config.headers
        , url = config.url
        , body = body "mutation" config.name sel
        , expect = expect identity sel
        , timeout = config.timeout
        , tracker = config.tracker
        }


{-|

      Http.request
        { method = "POST"
        , headers = []
        , url = "https://example.com/gql-endpoint"
        , body = Gql.body query
        , expect = Gql.expect Received query
        , timeout = Nothing
        , tracker = Nothing
        }

-}
body : String -> Maybe String -> Selection source data -> Http.Body
body operation maybeUnformattedName q =
    let
        maybeName =
            case maybeUnformattedName of
                Nothing ->
                    getOperationLabel q

                Just unformatted ->
                    Just (sanitizeOperationName unformatted)

        variables : Dict String VariableDetails
        variables =
            (getContext q).variables

        encodedVariables : Decode.Value
        encodedVariables =
            variables
                |> Dict.toList
                |> List.map (Tuple.mapSecond .value)
                |> Encode.object
    in
    Http.jsonBody
        (Encode.object
            (List.filterMap identity
                [ Maybe.map (\name -> ( "operationName", Encode.string name )) maybeName
                , Just ( "query", Encode.string (queryString operation maybeName q) )
                , Just ( "variables", encodedVariables )
                ]
            )
        )


{-|

      Http.request
        { method = "POST"
        , headers = []
        , url = "https://example.com/gql-endpoint"
        , body = Gql.body query
        , expect = Gql.expect Received query
        , timeout = Nothing
        , tracker = Nothing
        }

-}
bodyPremade : Premade data -> Encode.Value
bodyPremade (Premade q) =
    Encode.object
        (List.filterMap identity
            [ Just ( "query", Encode.string q.gql )
            , Just ( "variables", Encode.object q.args )
            ]
        )


{-|

    Operation names need to be formatted in a certain way.

    This is maybe too restrictive, but this keeps everything as [a-zA-Z0-9] and _

    None matching characters will be transformed to _.

-}
sanitizeOperationName : String -> String
sanitizeOperationName input =
    String.toList input
        |> List.map
            (\c ->
                if Char.isAlphaNum c || c == '_' then
                    c

                else
                    '_'
            )
        |> String.fromList


getContext : Selection source selected -> Context
getContext (Selection (Details gql _)) =
    let
        ( context, fields ) =
            gql empty
    in
    context


getOperationLabel : Selection source selected -> Maybe String
getOperationLabel (Selection (Details maybeLabel _ _)) =
    maybeLabel


{-| -}
expect : (Result Error data -> msg) -> Selection source data -> Http.Expect msg
expect toMsg (Selection (Details gql toDecoder)) =
    let
        ( context, decoder ) =
            toDecoder empty
    in
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.BadUrl_ url ->
                    Err (BadUrl url)

                Http.Timeout_ ->
                    Err Timeout

                Http.NetworkError_ ->
                    Err NetworkError

                Http.BadStatus_ metadata responseBody ->
                    Err
                        (BadStatus
                            { status = metadata.statusCode
                            , responseBody = responseBody
                            }
                        )

                Http.GoodStatus_ metadata responseBody ->
                    case Decode.decodeString (Decode.field "data" decoder) responseBody of
                        Ok value ->
                            Ok value

                        Err err ->
                            Err
                                (BadBody
                                    { responseBody = responseBody
                                    , decodingError = Decode.errorToString err
                                    }
                                )


{-| -}
expectPremade : Premade data -> Http.Expect (Result Error data)
expectPremade q =
    Http.expectStringResponse identity (decodePremade q)


decodePremade : Premade value -> Http.Response String -> Result Error value
decodePremade (Premade premadeQuery) response =
    case response of
        Http.BadUrl_ url ->
            Err (BadUrl url)

        Http.Timeout_ ->
            Err Timeout

        Http.NetworkError_ ->
            Err NetworkError

        Http.BadStatus_ metadata responseBody ->
            Err
                (BadStatus
                    { status = metadata.statusCode
                    , responseBody = responseBody
                    }
                )

        Http.GoodStatus_ metadata responseBody ->
            case Decode.decodeString (Decode.field "data" premadeQuery.decoder) responseBody of
                Ok value ->
                    Ok value

                Err err ->
                    Err
                        (BadBody
                            { responseBody = responseBody
                            , decodingError = Decode.errorToString err
                            }
                        )


{-| -}
type Error
    = BadUrl String
    | Timeout
    | NetworkError
    | BadStatus
        { status : Int
        , responseBody : String
        }
    | BadBody
        { decodingError : String
        , responseBody : String
        }


{-| -}
queryString : String -> Maybe String -> Selection source data -> String
queryString operation queryName (Selection (Details gql _)) =
    let
        ( context, fields ) =
            gql empty
    in
    operation
        ++ " "
        ++ Maybe.withDefault "" queryName
        ++ renderParameters context.variables
        ++ "{"
        ++ fieldsToQueryString fields ""
        ++ "}"


renderParameters : Dict String VariableDetails -> String
renderParameters dict =
    let
        paramList =
            Dict.toList dict
    in
    case paramList of
        [] ->
            ""

        _ ->
            "(" ++ renderParametersHelper paramList "" ++ ")"


renderParametersHelper : List ( String, VariableDetails ) -> String -> String
renderParametersHelper args rendered =
    case args of
        [] ->
            rendered

        ( name, value ) :: remaining ->
            if String.isEmpty rendered then
                renderParametersHelper remaining ("$" ++ name ++ ":" ++ value.gqlTypeName)

            else
                renderParametersHelper remaining (rendered ++ ", $" ++ name ++ ":" ++ value.gqlTypeName)


fieldsToQueryString : List Field -> String -> String
fieldsToQueryString fields rendered =
    case fields of
        [] ->
            rendered

        top :: remaining ->
            if String.isEmpty rendered then
                fieldsToQueryString remaining (renderField top)

            else
                fieldsToQueryString remaining (rendered ++ "\n" ++ renderField top)


renderField : Field -> String
renderField myField =
    case myField of
        Baked q ->
            q

        Fragment name fields ->
            "... on "
                ++ name
                ++ "{"
                ++ fieldsToQueryString fields ""
                ++ "}"

        Field name maybeAlias args fields ->
            let
                aliasString =
                    maybeAlias
                        |> Maybe.map (\a -> a ++ ":")
                        |> Maybe.withDefault ""

                argString =
                    case args of
                        [] ->
                            ""

                        nonEmpty ->
                            "(" ++ renderArgs nonEmpty "" ++ ")"

                selection =
                    case fields of
                        [] ->
                            ""

                        _ ->
                            "{" ++ fieldsToQueryString fields "" ++ "}"
            in
            aliasString ++ name ++ argString ++ selection


renderArgs : List ( String, Variable ) -> String -> String
renderArgs args rendered =
    case args of
        [] ->
            rendered

        ( name, Variable varName ) :: remaining ->
            if String.isEmpty rendered then
                renderArgs remaining (rendered ++ name ++ ": $" ++ varName)

            else
                renderArgs remaining (rendered ++ ", " ++ name ++ ": $" ++ varName)


argToString : Argument arg -> String
argToString argument =
    case argument of
        ArgValue json typename ->
            Encode.encode 0 json

        Var str ->
            "$" ++ str


argToTypeString : Argument arg -> String
argToTypeString argument =
    case argument of
        ArgValue v typename ->
            typename

        Var str ->
            ""


{-| -}
maybeScalarEncode : (a -> Encode.Value) -> Maybe a -> Encode.Value
maybeScalarEncode encoder maybeA =
    maybeA
        |> Maybe.map encoder
        |> Maybe.withDefault Encode.null


{-| -}
decodeNullable : Decode.Decoder data -> Decode.Decoder (Maybe data)
decodeNullable =
    Decode.nullable


jsonField :
    String
    -> Json.Decode.Decoder a
    -> Json.Decode.Decoder (a -> inner -> (inner -> inner2) -> inner2)
    -> Json.Decode.Decoder (inner -> (inner -> inner2) -> inner2)
jsonField name new build =
    Json.Decode.map2
        (\map2Unpack -> \unpack -> \inner inner2 -> inner2 inner)
        (Json.Decode.field name new)
        build


andMap :
    Json.Decode.Decoder map2Unpack
    -> Json.Decode.Decoder (map2Unpack -> inner -> (inner -> inner2) -> inner2)
    -> Json.Decode.Decoder (inner -> (inner -> inner2) -> inner2)
andMap new build =
    Json.Decode.map2
        (\map2Unpack -> \unpack -> \inner inner2 -> inner2 inner)
        new
        build
