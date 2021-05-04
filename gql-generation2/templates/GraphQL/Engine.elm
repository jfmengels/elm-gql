module GraphQL.Engine exposing
    ( Selection, select, with
    , map, map2, map3, map4, map5
    , Query, query
    , Mutation, mutation
    , Scalar, toScalarCodec, toScalar, fromScalar
    , Argument, args, optionalsToArguments
    , field, decoder
    , enum
    , union, fragment
    , Input, Optional, input
    )

{-|

@docs Selection, select, with
@docs map, map2, map3, map4, map5
@docs Query, query
@docs Mutation, mutation
@docs Scalar, toScalarCodec, toScalar, fromScalar
@docs Argument, args, optionalsToArguments
@docs field, decoder
@docs enum
@docs union, fragment
@docs Input, Optional, input

-}

import Codec exposing (Codec)
import Json.Decode as Json


type Selection kind value
    = Selection


select : value -> Selection kind value
select =
    Debug.todo "GraphQL.Engine.select"


with : Selection kind field -> Selection kind (field -> value) -> Selection kind value
with =
    Debug.todo "GraphQL.Engine.with"


map : (a -> b) -> Selection kind a -> Selection kind b
map =
    Debug.todo "map"


map2 : (a -> b -> c) -> Selection kind a -> Selection kind b -> Selection kind c
map2 =
    Debug.todo "map2"


map3 : (a -> b -> c -> d) -> Selection kind a -> Selection kind b -> Selection kind c -> Selection kind d
map3 =
    Debug.todo "map3"


map4 : (a -> b -> c -> d -> e) -> Selection kind a -> Selection kind b -> Selection kind c -> Selection kind d -> Selection kind e
map4 =
    Debug.todo "map4"


map5 : (a -> b -> c -> d -> e -> f) -> Selection kind a -> Selection kind b -> Selection kind c -> Selection kind d -> Selection kind e -> Selection kind f
map5 =
    Debug.todo "map5"


type Query
    = Query


query :
    String
    -> (Json.Decoder selection -> Json.Decoder value)
    -> Selection kind selection
    -> List ( String, Argument )
    -> Selection Query value
query =
    Debug.todo "query"


type Mutation
    = Mutation


mutation :
    String
    -> (Json.Decoder selection -> Json.Decoder value)
    -> Selection kind selection
    -> List ( String, Argument )
    -> Selection Mutation value
mutation =
    Debug.todo "mutation"


type Input kind
    = Input


type Optional kind
    = Optional


input : List ( String, Argument ) -> List (Optional any) -> Input kind
input =
    Debug.todo ""


fromInput : Input kind -> List ( String, Argument )
fromInput =
    Debug.todo ""



-- INPUTS


type Argument
    = Value Json.Value
    | Nested (List ( String, Argument ))


args :
    { value : Json.Value -> Argument
    , scalar : Codec (Scalar kind value) -> Scalar kind value -> Argument
    , input : Input kind -> Argument
    }
args =
    { value = Value
    , scalar = \codec -> Codec.encodeToValue codec >> Value
    , input = fromInput >> Nested
    }


optionalsToArguments : List (Optional any) -> List ( String, Argument )
optionalsToArguments =
    Debug.todo ""



-- SCALAR


type Scalar kind value
    = Scalar value


toScalarCodec : Codec value -> Codec (Scalar kind value)
toScalarCodec =
    Codec.map toScalar fromScalar


toScalar : value -> Scalar kind value
toScalar =
    Scalar


fromScalar : Scalar kind value -> value
fromScalar (Scalar value) =
    value



-- ENUM


enum : List ( String, enum ) -> Json.Decoder enum
enum =
    Debug.todo ""



--- FIELD


decoder : Selection kind value -> Json.Decoder value
decoder =
    Debug.todo "decoder"


field :
    (Json.Decoder selection -> Json.Decoder value)
    -> String
    -> Json.Decoder selection
    -> List ( String, Argument )
    -> Selection kind value
field =
    Debug.todo "field"



-- UNIONS


type Fragment value
    = Fragment


union : List ( String, Fragment value ) -> Selection kind value
union =
    Debug.todo "union"


fragment : Selection inner value -> Fragment value
fragment =
    Debug.todo "fragment"
