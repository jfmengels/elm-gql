export default (): string => "module GraphQL.Engine exposing\n    ( batch\n    , nullable, list, field, fieldWith, object, objectWith, decode\n    , enum, maybeEnum\n    , union\n    , Selection, select, with, map, map2, recover\n    , arg, argList, Optional, optional\n    , Query, query, Mutation, mutation, Error(..)\n    , prebakedQuery, Premade, premadeOperation\n    , queryString\n    , Argument(..), maybeScalarEncode\n    , encodeOptionals, encodeInputObject, encodeArgument\n    , decodeNullable, getGql, mapPremade\n    , unsafe, selectTypeNameButSkip\n    )\n\n{-|\n\n@docs batch\n\n@docs nullable, list, field, fieldWith, object, objectWith, decode\n\n@docs enum, maybeEnum\n\n@docs union\n\n@docs Selection, select, with, map, map2, recover\n\n@docs arg, argList, Optional, optional\n\n@docs Query, query, Mutation, mutation, Error\n\n@docs prebakedQuery, Premade, premadeOperation\n\n@docs queryString\n\n@docs Argument, maybeScalarEncode\n\n@docs encodeOptionals, encodeInputObject, encodeArgument\n\n@docs decodeNullable, getGql, mapPremade\n@docs unsafe, selectTypeNameButSkip\n\n-}\n\nimport Dict exposing (Dict)\nimport Http\nimport Json.Decode as Json\nimport Json.Encode as Encode\nimport Set\n\n\n{-| Batch a number of selection sets together!\n-}\nbatch : List (Selection source data) -> Selection source (List data)\nbatch selections =\n    Selection <|\n        Details\n            (\\context ->\n                List.foldl\n                    (\\(Selection (Details toFieldsGql _)) ( ctxt, fields ) ->\n                        let\n                            ( newCtxt, newFields ) =\n                                toFieldsGql ctxt\n                        in\n                        ( newCtxt\n                        , fields ++ newFields\n                        )\n                    )\n                    ( context, [] )\n                    selections\n            )\n            (\\context ->\n                List.foldl\n                    (\\(Selection (Details _ toItemDecoder)) ( ctxt, cursorFieldsDecoder ) ->\n                        let\n                            ( newCtxt, itemDecoder ) =\n                                toItemDecoder ctxt\n                        in\n                        ( newCtxt\n                        , cursorFieldsDecoder\n                            |> Json.andThen\n                                (\\existingList ->\n                                    Json.map\n                                        (\\item ->\n                                            item :: existingList\n                                        )\n                                        itemDecoder\n                                )\n                        )\n                    )\n                    ( context, Json.succeed [] )\n                    selections\n            )\n\n\n{-| -}\nrecover : recovered -> (data -> recovered) -> Selection source data -> Selection source recovered\nrecover default wrapValue (Selection (Details toQuery toDecoder)) =\n    Selection\n        (Details toQuery\n            (\\context ->\n                let\n                    ( newContext, decoder ) =\n                        toDecoder context\n                in\n                ( newContext\n                , Json.oneOf\n                    [ Json.map wrapValue decoder\n                    , Json.succeed default\n                    ]\n                )\n            )\n        )\n\n\n{-| -}\nunion : List ( String, Selection source data ) -> Selection source data\nunion options =\n    Selection <|\n        Details\n            (\\context ->\n                let\n                    ( fragments, fragmentContext ) =\n                        List.foldl\n                            (\\( name, Selection (Details fragQuery _) ) ( frags, currentContext ) ->\n                                let\n                                    ( newContext, fields ) =\n                                        fragQuery currentContext\n\n                                    nonEmptyFields =\n                                        case fields of\n                                            [] ->\n                                                -- we're already selecting typename at the root.\n                                                -- this is just so we don't have an empty set of brackets\n                                                [ Field \"__typename\" Nothing [] [] ]\n\n                                            _ ->\n                                                fields\n                                in\n                                ( Fragment name nonEmptyFields :: frags\n                                , newContext\n                                )\n                            )\n                            ( [], context )\n                            options\n                in\n                ( fragmentContext\n                , Field \"__typename\" Nothing [] [] :: fragments\n                )\n            )\n            (\\context ->\n                let\n                    ( fragmentDecoders, fragmentContext ) =\n                        List.foldl\n                            (\\( name, Selection (Details _ toFragDecoder) ) ( frags, currentContext ) ->\n                                let\n                                    ( newContext, fragDecoder ) =\n                                        toFragDecoder currentContext\n\n                                    fragDecoderWithTypename =\n                                        Json.field \"__typename\" Json.string\n                                            |> Json.andThen\n                                                (\\typename ->\n                                                    if typename == name then\n                                                        fragDecoder\n\n                                                    else\n                                                        Json.fail \"Unknown union variant\"\n                                                )\n                                in\n                                ( fragDecoderWithTypename :: frags\n                                , newContext\n                                )\n                            )\n                            ( [], context )\n                            options\n                in\n                ( fragmentContext\n                , Json.oneOf fragmentDecoders\n                )\n            )\n\n\n{-| -}\nmaybeEnum : List ( String, item ) -> Json.Decoder (Maybe item)\nmaybeEnum options =\n    Json.oneOf\n        [ Json.map Just (enum options)\n        , Json.succeed Nothing\n        ]\n\n\n{-| -}\nenum : List ( String, item ) -> Json.Decoder item\nenum options =\n    Json.string\n        |> Json.andThen\n            (findFirstMatch options)\n\n\nfindFirstMatch : List ( String, item ) -> String -> Json.Decoder item\nfindFirstMatch options str =\n    case options of\n        [] ->\n            Json.fail (\"Unexpected enum value: \" ++ str)\n\n        ( name, value ) :: remaining ->\n            if name == str then\n                Json.succeed value\n\n            else\n                findFirstMatch remaining str\n\n\n{-| Used in generated code to handle maybes\n-}\nnullable : Selection source data -> Selection source (Maybe data)\nnullable (Selection (Details toFieldsGql toFieldsDecoder)) =\n    Selection <|\n        Details\n            toFieldsGql\n            (\\context ->\n                let\n                    ( fieldContext, fieldsDecoder ) =\n                        toFieldsDecoder context\n                in\n                ( fieldContext\n                , Json.oneOf\n                    [ Json.map Just fieldsDecoder\n                    , Json.succeed Nothing\n                    ]\n                )\n            )\n\n\n{-| Used in generated code to handle maybes\n-}\nlist : Selection source data -> Selection source (List data)\nlist (Selection (Details toFieldsGql toFieldsDecoder)) =\n    Selection <|\n        Details\n            toFieldsGql\n            (\\context ->\n                let\n                    ( fieldContext, fieldsDecoder ) =\n                        toFieldsDecoder context\n                in\n                ( fieldContext\n                , Json.list fieldsDecoder\n                )\n            )\n\n\n{-| -}\nobject : String -> Selection source data -> Selection otherSource data\nobject =\n    objectWith []\n\n\n{-| -}\nobjectWith : List ( String, Argument arg ) -> String -> Selection source data -> Selection otherSource data\nobjectWith args name (Selection (Details toFieldsGql toFieldsDecoder)) =\n    Selection <|\n        Details\n            (\\context ->\n                let\n                    ( fieldContext, fields ) =\n                        toFieldsGql { context | aliases = Dict.empty }\n\n                    new =\n                        applyContext args name { fieldContext | aliases = context.aliases }\n                in\n                ( new.context\n                , [ Field name new.aliasString new.args fields\n                  ]\n                )\n            )\n            (\\context ->\n                let\n                    ( fieldContext, fieldsDecoder ) =\n                        toFieldsDecoder { context | aliases = Dict.empty }\n\n                    new =\n                        applyContext args name { fieldContext | aliases = context.aliases }\n\n                    aliasedName =\n                        Maybe.withDefault name new.aliasString\n                in\n                ( new.context\n                , Json.field aliasedName fieldsDecoder\n                )\n            )\n\n\n{-| This adds a bare decoder for data that has already been pulled down.\n\nNote, this is rarely needed! So far, only when a query or mutation returns a scalar directly without selecting any fields.\n\n-}\ndecode : Json.Decoder data -> Selection source data\ndecode decoder =\n    Selection <|\n        Details\n            (\\context ->\n                ( context\n                , []\n                )\n            )\n            (\\context ->\n                ( context\n                , decoder\n                )\n            )\n\n\n{-| -}\nselectTypeNameButSkip : Selection source ()\nselectTypeNameButSkip =\n    Selection <|\n        Details\n            (\\context ->\n                ( context\n                , [ Field \"__typename\" Nothing [] []\n                  ]\n                )\n            )\n            (\\context ->\n                ( context\n                , Json.succeed ()\n                )\n            )\n\n\n{-| -}\nfield : String -> Json.Decoder data -> Selection source data\nfield =\n    fieldWith []\n\n\n{-| -}\nfieldWith : List ( String, Argument arg ) -> String -> Json.Decoder data -> Selection source data\nfieldWith args name decoder =\n    Selection <|\n        Details\n            (\\context ->\n                let\n                    new =\n                        applyContext args name context\n                in\n                ( new.context\n                , [ Field name new.aliasString new.args []\n                  ]\n                )\n            )\n            (\\context ->\n                let\n                    new =\n                        applyContext args name context\n\n                    aliasedName =\n                        Maybe.withDefault name new.aliasString\n                in\n                ( new.context\n                , Json.field aliasedName decoder\n                )\n            )\n\n\napplyContext :\n    List ( String, Argument arg )\n    -> String\n    -> Context\n    ->\n        { context : Context\n        , aliasString : Maybe String\n        , args : List ( String, Argument Free )\n        }\napplyContext args name context =\n    let\n        ( maybeAlias, newAliases ) =\n            makeAlias name context.aliases\n\n        ( vars, newVariables ) =\n            captureArgs args context.variables\n    in\n    { context =\n        { aliases = newAliases\n        , variables = newVariables\n        }\n    , aliasString = maybeAlias\n    , args = vars\n    }\n\n\ncaptureArgs : List ( String, Argument arg ) -> Dict String (Argument Free) -> ( List ( String, Argument Free ), Dict String (Argument Free) )\ncaptureArgs args context =\n    case args of\n        [] ->\n            ( [], context )\n\n        _ ->\n            captureArgsHelper args context []\n\n\ncaptureArgsHelper : List ( String, Argument arg ) -> Dict String (Argument Free) -> List ( String, Argument Free ) -> ( List ( String, Argument Free ), Dict String (Argument Free) )\ncaptureArgsHelper args context alreadyPassed =\n    case args of\n        [] ->\n            ( alreadyPassed, context )\n\n        ( name, value ) :: remaining ->\n            let\n                varname =\n                    getValidVariableName name 0 context\n\n                newContext =\n                    Dict.insert varname (toFree value) context\n            in\n            captureArgsHelper remaining newContext (( name, Var varname ) :: alreadyPassed)\n\n\ngetValidVariableName : String -> Int -> Dict String (Argument Free) -> String\ngetValidVariableName str index used =\n    let\n        attemptedName =\n            if index == 0 then\n                str\n\n            else\n                str ++ String.fromInt index\n    in\n    if Dict.member attemptedName used then\n        getValidVariableName str (index + 1) used\n\n    else\n        attemptedName\n\n\nmakeAlias : String -> Dict String Int -> ( Maybe String, Dict String Int )\nmakeAlias name aliases =\n    case Dict.get name aliases of\n        Nothing ->\n            ( Nothing, Dict.insert name 0 aliases )\n\n        Just found ->\n            ( Just (name ++ String.fromInt (found + 1))\n            , Dict.insert name (found + 1) aliases\n            )\n\n\n{-| -}\ntype Selection source selected\n    = Selection (Details selected)\n\n\ntype alias Context =\n    { aliases : Dict String Int\n    , variables : Dict String (Argument Free)\n    }\n\n\n{-| -}\nunsafe : Selection source selected -> Selection unsafe selected\nunsafe (Selection deets) =\n    Selection deets\n\n\ntype Free\n    = Free\n\n\ntoFree : Argument thing -> Argument Free\ntoFree argument =\n    case argument of\n        ArgValue json tag ->\n            ArgValue json tag\n\n        Var varname ->\n            Var varname\n\n\nempty : Context\nempty =\n    { aliases = Dict.empty\n    , variables = Dict.empty\n    }\n\n\n{-| An unguarded GQL query.\n-}\ntype Details selected\n    = Details\n        -- Both of these take a Set String, which is how we're keeping track of\n        -- what needs to be aliased\n        -- How to make the gql query\n        (Context -> ( Context, List Field ))\n        -- How to decode the data coming back\n        (Context -> ( Context, Json.Decoder selected ))\n\n\ntype Field\n    = --    name   alias          args                        children\n      Field String (Maybe String) (List ( String, Argument Free )) (List Field)\n      --        ...on FragmentName\n    | Fragment String (List Field)\n      -- a piece of GQL that has been validated separately\n      -- This is generally for operational gql\n    | Baked String\n\n\n{-| We can also accept:\n\n  - Enum values (unquoted)\n  - custom scalars\n\nBut we can define anything else in terms of these:\n\n-}\ntype Argument obj\n    = ArgValue Encode.Value String\n    | Var String\n\n\n{-| -}\ntype Optional arg\n    = Optional String (Argument arg)\n\n\n{-| The encoded value and the name of the expected type for this argument\n-}\narg : Encode.Value -> String -> Argument obj\narg val typename =\n    ArgValue val typename\n\n\n{-| -}\nargList : List (Argument obj) -> String -> Argument input\nargList fields typeName =\n    ArgValue\n        (fields\n            |> Encode.list\n                (\\argVal ->\n                    case argVal of\n                        ArgValue val _ ->\n                            val\n\n                        Var varName ->\n                            Encode.string varName\n                )\n        )\n        typeName\n\n\n{-| -}\nencodeInputObject : List ( String, Argument obj ) -> String -> Argument input\nencodeInputObject fields typeName =\n    ArgValue\n        (fields\n            |> List.map\n                (\\( name, argVal ) ->\n                    case argVal of\n                        ArgValue val _ ->\n                            ( name, val )\n\n                        Var varName ->\n                            ( name, Encode.string varName )\n                )\n            |> Encode.object\n        )\n        typeName\n\n\n{-| -}\nencodeArgument : Argument obj -> Encode.Value\nencodeArgument argVal =\n    case argVal of\n        ArgValue val _ ->\n            val\n\n        Var varName ->\n            Encode.string varName\n\n\n{-| -}\nencodeOptionals : List (Optional arg) -> List ( String, Argument arg )\nencodeOptionals opts =\n    List.foldl\n        (\\(Optional optName argument) (( found, gathered ) as skip) ->\n            if Set.member optName found then\n                skip\n\n            else\n                ( Set.insert optName found\n                , ( optName, argument ) :: gathered\n                )\n        )\n        ( Set.empty, [] )\n        opts\n        |> Tuple.second\n\n\n{-|\n\n    Encode the nullability in the argument itself.\n\n-}\noptional : String -> Argument arg -> Optional arg\noptional =\n    Optional\n\n\n{-| -}\nselect : data -> Selection source data\nselect data =\n    Selection\n        (Details\n            (\\context ->\n                ( context, [] )\n            )\n            (\\context ->\n                ( context, Json.succeed data )\n            )\n        )\n\n\n{-| -}\nwith : Selection source a -> Selection source (a -> b) -> Selection source b\nwith =\n    map2 (|>)\n\n\n{-| -}\nmap : (a -> b) -> Selection source a -> Selection source b\nmap fn (Selection (Details fields decoder)) =\n    Selection <|\n        Details fields\n            (\\aliases ->\n                let\n                    ( newAliases, newDecoder ) =\n                        decoder aliases\n                in\n                ( newAliases, Json.map fn newDecoder )\n            )\n\n\n{-| -}\nmap2 : (a -> b -> c) -> Selection source a -> Selection source b -> Selection source c\nmap2 fn (Selection (Details oneFields oneDecoder)) (Selection (Details twoFields twoDecoder)) =\n    Selection <|\n        Details\n            (\\aliases ->\n                let\n                    ( oneAliasesNew, oneFieldsNew ) =\n                        oneFields aliases\n\n                    ( twoAliasesNew, twoFieldsNew ) =\n                        twoFields oneAliasesNew\n                in\n                ( twoAliasesNew\n                , oneFieldsNew ++ twoFieldsNew\n                )\n            )\n            (\\aliases ->\n                let\n                    ( oneAliasesNew, oneDecoderNew ) =\n                        oneDecoder aliases\n\n                    ( twoAliasesNew, twoDecoderNew ) =\n                        twoDecoder oneAliasesNew\n                in\n                ( twoAliasesNew\n                , Json.map2 fn oneDecoderNew twoDecoderNew\n                )\n            )\n\n\n{-| -}\nprebakedQuery : String -> List ( String, Encode.Value ) -> Json.Decoder data -> Premade data\nprebakedQuery gql args decoder =\n    Premade\n        { gql = gql\n        , args = args\n        , decoder = decoder\n        }\n\n\n\n{- Making requests -}\n\n\n{-| -}\ntype Premade data\n    = Premade\n        { gql : String\n        , decoder : Json.Decoder data\n        , args : List ( String, Encode.Value )\n        }\n\n\n{-| -}\ntype Query\n    = Query\n\n\n{-| -}\ntype Mutation\n    = Mutation\n\n\n{-| -}\ngetGql : Premade data -> String\ngetGql (Premade { gql }) =\n    gql\n\n\n{-| -}\nmapPremade : (a -> b) -> Premade a -> Premade b\nmapPremade fn (Premade details) =\n    Premade\n        { gql = details.gql\n        , decoder = Json.map fn details.decoder\n        , args = details.args\n        }\n\n\n{-| -}\npremadeOperation :\n    Premade value\n    ->\n        { headers : List Http.Header\n        , url : String\n        , timeout : Maybe Float\n        , tracker : Maybe String\n        }\n    -> Cmd (Result Error value)\npremadeOperation sel config =\n    Http.request\n        { method = \"POST\"\n        , headers = config.headers\n        , url = config.url\n        , body = bodyPremade sel\n        , expect = expectPremade sel\n        , timeout = config.timeout\n        , tracker = config.tracker\n        }\n\n\n{-| -}\nquery :\n    Selection Query value\n    ->\n        { name : Maybe String\n        , headers : List Http.Header\n        , url : String\n        , timeout : Maybe Float\n        , tracker : Maybe String\n        }\n    -> Cmd (Result Error value)\nquery sel config =\n    Http.request\n        { method = \"POST\"\n        , headers = config.headers\n        , url = config.url\n        , body = body \"query\" config.name sel\n        , expect = expect identity sel\n        , timeout = config.timeout\n        , tracker = config.tracker\n        }\n\n\n{-| -}\nmutation :\n    Selection Mutation msg\n    ->\n        { name : Maybe String\n        , headers : List Http.Header\n        , url : String\n        , timeout : Maybe Float\n        , tracker : Maybe String\n        }\n    -> Cmd (Result Error msg)\nmutation sel config =\n    Http.request\n        { method = \"POST\"\n        , headers = config.headers\n        , url = config.url\n        , body = body \"mutation\" config.name sel\n        , expect = expect identity sel\n        , timeout = config.timeout\n        , tracker = config.tracker\n        }\n\n\n{-|\n\n      Http.request\n        { method = \"POST\"\n        , headers = []\n        , url = \"https://example.com/gql-endpoint\"\n        , body = Gql.body query\n        , expect = Gql.expect Received query\n        , timeout = Nothing\n        , tracker = Nothing\n        }\n\n-}\nbody : String -> Maybe String -> Selection source data -> Http.Body\nbody operation maybeUnformattedName q =\n    let\n        maybeName =\n            maybeUnformattedName\n                |> Maybe.map\n                    sanitizeOperationName\n\n        variables : Dict String (Argument Free)\n        variables =\n            (getContext q).variables\n\n        encodedVariables : Json.Value\n        encodedVariables =\n            variables\n                |> Dict.toList\n                |> List.map (Tuple.mapSecond toValue)\n                |> Encode.object\n\n        toValue : Argument arg -> Json.Value\n        toValue arg_ =\n            case arg_ of\n                ArgValue value str ->\n                    value\n\n                Var str ->\n                    Encode.string str\n    in\n    Http.jsonBody\n        (Encode.object\n            (List.filterMap identity\n                [ Maybe.map (\\name -> ( \"operationName\", Encode.string name )) maybeName\n                , Just ( \"query\", Encode.string (queryString operation maybeName q) )\n                , Just ( \"variables\", encodedVariables )\n                ]\n            )\n        )\n\n\n{-|\n\n      Http.request\n        { method = \"POST\"\n        , headers = []\n        , url = \"https://example.com/gql-endpoint\"\n        , body = Gql.body query\n        , expect = Gql.expect Received query\n        , timeout = Nothing\n        , tracker = Nothing\n        }\n\n-}\nbodyPremade : Premade data -> Http.Body\nbodyPremade (Premade q) =\n    Http.jsonBody\n        (Encode.object\n            (List.filterMap identity\n                [ Just ( \"query\", Encode.string q.gql )\n                , Just ( \"variables\", Encode.object q.args )\n                ]\n            )\n        )\n\n\n{-|\n\n    Operation names need to be formatted in a certain way.\n\n    This is maybe too restrictive, but this keeps everything as [a-zA-Z0-9] and _\n\n    None mathcing characters will be transformed to _.\n\n-}\nsanitizeOperationName : String -> String\nsanitizeOperationName input =\n    String.toList input\n        |> List.map\n            (\\c ->\n                if Char.isAlphaNum c || c == '_' then\n                    c\n\n                else\n                    '_'\n            )\n        |> String.fromList\n\n\ngetContext : Selection source selected -> Context\ngetContext (Selection (Details gql _)) =\n    let\n        ( context, fields ) =\n            gql empty\n    in\n    context\n\n\n{-| -}\nexpect : (Result Error data -> msg) -> Selection source data -> Http.Expect msg\nexpect toMsg (Selection (Details gql toDecoder)) =\n    let\n        ( context, decoder ) =\n            toDecoder empty\n    in\n    Http.expectStringResponse toMsg <|\n        \\response ->\n            case response of\n                Http.BadUrl_ url ->\n                    Err (BadUrl url)\n\n                Http.Timeout_ ->\n                    Err Timeout\n\n                Http.NetworkError_ ->\n                    Err NetworkError\n\n                Http.BadStatus_ metadata responseBody ->\n                    Err\n                        (BadStatus\n                            { status = metadata.statusCode\n                            , responseBody = responseBody\n                            }\n                        )\n\n                Http.GoodStatus_ metadata responseBody ->\n                    case Json.decodeString (Json.field \"data\" decoder) responseBody of\n                        Ok value ->\n                            Ok value\n\n                        Err err ->\n                            Err\n                                (BadBody\n                                    { responseBody = responseBody\n                                    , decodingError = Json.errorToString err\n                                    }\n                                )\n\n\n{-| -}\nexpectPremade : Premade data -> Http.Expect (Result Error data)\nexpectPremade (Premade premadeQuery) =\n    Http.expectStringResponse identity <|\n        \\response ->\n            case response of\n                Http.BadUrl_ url ->\n                    Err (BadUrl url)\n\n                Http.Timeout_ ->\n                    Err Timeout\n\n                Http.NetworkError_ ->\n                    Err NetworkError\n\n                Http.BadStatus_ metadata responseBody ->\n                    Err\n                        (BadStatus\n                            { status = metadata.statusCode\n                            , responseBody = responseBody\n                            }\n                        )\n\n                Http.GoodStatus_ metadata responseBody ->\n                    case Json.decodeString (Json.field \"data\" premadeQuery.decoder) responseBody of\n                        Ok value ->\n                            Ok value\n\n                        Err err ->\n                            Err\n                                (BadBody\n                                    { responseBody = responseBody\n                                    , decodingError = Json.errorToString err\n                                    }\n                                )\n\n\n{-| -}\ntype Error\n    = BadUrl String\n    | Timeout\n    | NetworkError\n    | BadStatus\n        { status : Int\n        , responseBody : String\n        }\n    | BadBody\n        { decodingError : String\n        , responseBody : String\n        }\n\n\n{-| -}\nqueryString : String -> Maybe String -> Selection source data -> String\nqueryString operation queryName (Selection (Details gql _)) =\n    let\n        ( context, fields ) =\n            gql empty\n    in\n    operation\n        ++ \" \"\n        ++ Maybe.withDefault \"\" queryName\n        ++ renderParameters context.variables\n        ++ \"{\"\n        ++ fieldsToQueryString fields \"\"\n        ++ \"}\"\n\n\nrenderParameters : Dict String (Argument arg) -> String\nrenderParameters dict =\n    let\n        paramList =\n            Dict.toList dict\n    in\n    case paramList of\n        [] ->\n            \"\"\n\n        _ ->\n            \"(\" ++ renderParametersHelper paramList \"\" ++ \")\"\n\n\nrenderParametersHelper : List ( String, Argument arg ) -> String -> String\nrenderParametersHelper args rendered =\n    case args of\n        [] ->\n            rendered\n\n        ( name, value ) :: remaining ->\n            if String.isEmpty rendered then\n                renderParametersHelper remaining (\"$\" ++ name ++ \":\" ++ argToTypeString value)\n\n            else\n                renderParametersHelper remaining (rendered ++ \", $\" ++ name ++ \":\" ++ argToTypeString value)\n\n\nfieldsToQueryString : List Field -> String -> String\nfieldsToQueryString fields rendered =\n    case fields of\n        [] ->\n            rendered\n\n        top :: remaining ->\n            if String.isEmpty rendered then\n                fieldsToQueryString remaining (renderField top)\n\n            else\n                fieldsToQueryString remaining (rendered ++ \"\\n\" ++ renderField top)\n\n\nrenderField : Field -> String\nrenderField myField =\n    case myField of\n        Baked q ->\n            q\n\n        Fragment name fields ->\n            \"... on \"\n                ++ name\n                ++ \"{\"\n                ++ fieldsToQueryString fields \"\"\n                ++ \"}\"\n\n        Field name maybeAlias args fields ->\n            let\n                aliasString =\n                    maybeAlias\n                        |> Maybe.map (\\a -> a ++ \":\")\n                        |> Maybe.withDefault \"\"\n\n                argString =\n                    case args of\n                        [] ->\n                            \"\"\n\n                        nonEmpty ->\n                            \"(\" ++ renderArgs nonEmpty \"\" ++ \")\"\n\n                selection =\n                    case fields of\n                        [] ->\n                            \"\"\n\n                        _ ->\n                            \"{\" ++ fieldsToQueryString fields \"\" ++ \"}\"\n            in\n            aliasString ++ name ++ argString ++ selection\n\n\nrenderArgs : List ( String, Argument arg ) -> String -> String\nrenderArgs args rendered =\n    case args of\n        [] ->\n            rendered\n\n        ( name, top ) :: remaining ->\n            if String.isEmpty rendered then\n                renderArgs remaining (rendered ++ name ++ \": \" ++ argToString top)\n\n            else\n                renderArgs remaining (rendered ++ \", \" ++ name ++ \": \" ++ argToString top)\n\n\nargToString : Argument arg -> String\nargToString argument =\n    case argument of\n        ArgValue json typename ->\n            Encode.encode 0 json\n\n        Var str ->\n            \"$\" ++ str\n\n\nargToTypeString : Argument arg -> String\nargToTypeString argument =\n    case argument of\n        ArgValue v typename ->\n            typename\n\n        Var str ->\n            \"\"\n\n\n{-| -}\nmaybeScalarEncode : (a -> Encode.Value) -> Maybe a -> Encode.Value\nmaybeScalarEncode encoder maybeA =\n    maybeA\n        |> Maybe.map encoder\n        |> Maybe.withDefault Encode.null\n\n\n{-| -}\ndecodeNullable : Json.Decoder data -> Json.Decoder (Maybe data)\ndecodeNullable =\n    Json.nullable\n"