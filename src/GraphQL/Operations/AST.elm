module GraphQL.Operations.AST exposing (..)


type alias Document =
    { definitions : List Definition
    }


type Definition
    = Fragment FragmentDetails
    | Operation OperationDetails


type alias FragmentDetails =
    { name : Name
    , typeCondition : Name
    , directives : List Directive
    , selection : List Selection
    }


type alias OperationDetails =
    { operationType : OperationType
    , name : Maybe Name
    , variableDefinitions : List VariableDefinition
    , directives : List Directive
    , fields : List Selection
    }


type OperationType
    = Query
    | Mutation


type alias VariableDefinition =
    { variable : Variable
    , type_ : Type
    , defaultValue : Maybe Value
    }


type alias Variable =
    { name : Name
    }


type Selection
    = Field FieldDetails
    | FragmentSpreadSelection FragmentSpread
    | InlineFragmentSelection InlineFragment


type alias FieldDetails =
    { alias_ : Maybe Name
    , name : Name
    , arguments : List Argument
    , directives : List Directive
    , selection : List Selection
    }


type alias FragmentSpread =
    { name : Name
    , directives : List Directive
    }


type alias InlineFragment =
    { tag : Name
    , directives : List Directive
    , selection : List Selection
    }


type Name
    = Name String


getAliasedName : FieldDetails -> String
getAliasedName deets =
    Maybe.withDefault deets.name deets.alias_
        |> nameToString


nameToString : Name -> String
nameToString (Name str) =
    str


type Value
    = Str String
    | Integer Int
    | Decimal Float
    | Boolean Bool
    | Null
    | Enum Name
    | Var Variable
    | Object (List ( Name, Value ))
    | ListValue (List Value)


valueToString : Value -> String
valueToString v =
    case v of
        Str str ->
            "\"" ++ str ++ "\""

        Integer i ->
            String.fromInt i

        Decimal f ->
            String.fromFloat f

        Boolean True ->
            "true"

        Boolean False ->
            "false"

        Null ->
            "null"

        Enum name ->
            nameToString name

        Var variable ->
            "$" ++ nameToString variable.name

        Object fields ->
            "{ "
                ++ String.join ", "
                    (List.map
                        (\( name, value ) ->
                            nameToString name
                                ++ ": "
                                ++ valueToString value
                        )
                        fields
                    )
                ++ " }"

        ListValue vals ->
            "[ " ++ String.join ", " (List.map valueToString vals) ++ " ]"


type alias Argument =
    { name : Name
    , value : Value
    }


type alias Directive =
    { name : Name
    , arguments : List Argument
    }


type Type
    = Type_ Name
    | List_ Type
    | Nullable Type


brackets : String -> String
brackets str =
    "{" ++ str ++ "}"


type Wrapper
    = InList { required : Bool } Wrapper
    | Val { required : Bool }


typeToGqlString : Type -> String
typeToGqlString t =
    typeToString (getWrapper t (Val { required = True })) t


{-|

    Type ->
        Required Val

    Nullable Type ->
        Val

-}
getWrapper : Type -> Wrapper -> Wrapper
getWrapper t wrap =
    case t of
        Type_ _ ->
            wrap

        List_ inner ->
            getWrapper inner wrap

        Nullable inner ->
            case wrap of
                Val { required } ->
                    getWrapper inner (Val { required = False })

                InList { required } wrapper ->
                    getWrapper inner (InList { required = False } wrapper)


typeToString : Wrapper -> Type -> String
typeToString wrapper t =
    case t of
        Type_ (Name str) ->
            unwrap wrapper str

        List_ inner ->
            typeToString wrapper inner

        Nullable inner ->
            typeToString wrapper inner


unwrap : Wrapper -> String -> String
unwrap wrapper str =
    case wrapper of
        Val { required } ->
            if required then
                str ++ "!"

            else
                str

        InList { required } inner ->
            if required then
                unwrap inner ("[" ++ str ++ "]!")

            else
                unwrap inner ("[" ++ str ++ "]")
