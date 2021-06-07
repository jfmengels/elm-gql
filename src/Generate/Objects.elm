module Generate.Objects exposing (generateFiles)

import Dict
import Elm
import Elm.Annotation
import Elm.Gen.GraphQL.Engine as Engine
import Elm.Gen.Json.Decode as Json
import Elm.Pattern
import Generate.Common as Common
import GraphQL.Schema
import GraphQL.Schema.Object
import GraphQL.Schema.Type exposing (Type(..))
import String.Extra as String
import Utils.String



-- target:
-- module TnGql.Object.App exposing (..)
-- import Json.Decode as Decode exposing (Decoder)
-- import TnGql.Object
-- import GraphQL.Engine as Engine
-- app : { name : Engine.Selection Tng.Object.App String, slug : Engine.Selection Tng.Object.App String  }
-- app =
--     { name = Engine.field "name" Decode.string
--     , slug = Engine.field "slug" Decode.string
--     }


objectToModule : GraphQL.Schema.Object.Object -> Elm.File
objectToModule object =
    let
        fieldTypesAndImpls =
            object.fields
                --|> List.filter
                --    (\field ->
                --        List.member field.name [ "name", "slug", "id", "viewUrl", "parent" ]
                --    )
                |> List.foldl
                    (\field accDecls ->
                        let
                            implemented =
                                implementField object.name
                                    field.name
                                    field.type_
                                    UnwrappedValue
                        in
                        ( field.name, implemented.annotation, implemented.expression ) :: accDecls
                    )
                    []

        -- GQL.Query (Maybe value)
        objectTypeAnnotation =
            fieldTypesAndImpls
                |> List.map (\( name, typeAnnotation, _ ) -> ( name, typeAnnotation ))
                |> Elm.Annotation.record

        objectImplementation =
            fieldTypesAndImpls
                |> List.map (\( name, _, expression ) -> ( name, expression ))
                |> Elm.record

        objectDecl =
            Elm.declarationWith (String.decapitalize object.name) objectTypeAnnotation objectImplementation
    in
    Elm.file (Elm.moduleName [ "TnGql", "Object", object.name ])
        ""
        [ objectDecl |> Elm.expose
        ]


type Wrapped
    = UnwrappedValue
    | InList Wrapped
    | InMaybe Wrapped


implementField :
    String
    -> String
    -> Type
    -> Wrapped
    ->
        { expression : Elm.Expression
        , annotation : Elm.Annotation.Annotation
        }
implementField objectName fieldName fieldType wrapped =
    case fieldType of
        GraphQL.Schema.Type.Nullable newType ->
            implementField objectName fieldName newType (InMaybe wrapped)

        GraphQL.Schema.Type.List_ newType ->
            implementField objectName fieldName newType (InList wrapped)

        GraphQL.Schema.Type.Scalar scalarName ->
            let
                signature =
                    fieldSignature objectName fieldType
            in
            { expression =
                Engine.field
                    (Elm.string fieldName)
                    (decodeScalar scalarName wrapped)
            , annotation = signature.annotation
            }

        GraphQL.Schema.Type.Enum enumName ->
            let
                signature =
                    fieldSignature objectName fieldType
            in
            { expression =
                Engine.field
                    (Elm.string fieldName)
                    (Elm.valueFrom (Elm.moduleName [ "TnGql", "Enum", enumName ]) "decoder")
            , annotation = signature.annotation
            }

        GraphQL.Schema.Type.Object nestedObjectName ->
            { expression =
                Elm.lambda "selection_"
                    (Elm.Annotation.namedWith (Elm.moduleName [ "GraphQL", "Engine" ])
                        "Selection"
                        [ Elm.Annotation.named (Elm.moduleName [ "TnGql", "Object" ]) nestedObjectName
                        , Elm.Annotation.var "data"
                        ]
                    )
                    (\sel ->
                        Engine.object
                            (Elm.string fieldName)
                            (wrapExpression wrapped sel)
                    )
            , annotation =
                Elm.Annotation.function
                    [ Elm.Annotation.namedWith (Elm.moduleName [ "GraphQL", "Engine" ])
                        "Selection"
                        [ Elm.Annotation.named (Elm.moduleName [ "TnGql", "Object" ]) nestedObjectName
                        , Elm.Annotation.var "data"
                        ]
                    ]
                    (Elm.Annotation.namedWith (Elm.moduleName [ "GraphQL", "Engine" ])
                        "Selection"
                        [ Elm.Annotation.named (Elm.moduleName [ "TnGql", "Object" ]) objectName
                        , wrapAnnotation wrapped (Elm.Annotation.var "data")
                        ]
                    )
            }

        GraphQL.Schema.Type.Interface interfaceName ->
            let
                signature =
                    fieldSignature objectName fieldType
            in
            { expression = Elm.string ("unimplemented: " ++ Debug.toString fieldType)
            , annotation = signature.annotation
            }

        GraphQL.Schema.Type.InputObject inputName ->
            let
                signature =
                    fieldSignature objectName fieldType
            in
            { expression = Elm.string ("unimplemented: " ++ Debug.toString fieldType)
            , annotation = signature.annotation
            }

        GraphQL.Schema.Type.Union unionName ->
            { expression =
                Elm.lambda "union_"
                    (Elm.Annotation.namedWith (Elm.moduleName [ "GraphQL", "Engine" ]) unionName [ Elm.Annotation.var "data" ])
                    (\un ->
                        Engine.object
                            (Elm.string fieldName)
                            (wrapExpression wrapped un)
                    )
            , annotation =
                Elm.Annotation.function
                    [ Elm.Annotation.namedWith (Elm.moduleName [ "GraphQL", "Engine" ]) unionName [ Elm.Annotation.var "data" ] ]
                    (Elm.Annotation.namedWith (Elm.moduleName [ "GraphQL", "Engine" ]) objectName [ wrapAnnotation wrapped (Elm.Annotation.var "data") ])
            }


wrapAnnotation : Wrapped -> Elm.Annotation.Annotation -> Elm.Annotation.Annotation
wrapAnnotation wrap signature =
    case wrap of
        UnwrappedValue ->
            signature

        InList inner ->
            Elm.Annotation.list (wrapAnnotation inner signature)

        InMaybe inner ->
            Elm.Annotation.maybe (wrapAnnotation inner signature)


wrapExpression : Wrapped -> Elm.Expression -> Elm.Expression
wrapExpression wrap exp =
    case wrap of
        UnwrappedValue ->
            exp

        InList inner ->
            Elm.apply (Elm.valueFrom (Elm.moduleName [ "Json", "Decode" ]) "list")
                [ wrapExpression inner exp
                ]

        InMaybe inner ->
            Engine.nullable
                (wrapExpression inner exp)


fieldSignature :
    String
    -> Type
    ->
        { annotation : Elm.Annotation.Annotation
        }
fieldSignature objectName fieldType =
    let
        dataType =
            Common.gqlTypeToElmTypeAnnotation fieldType Nothing

        typeAnnotation =
            Elm.Annotation.namedWith (Elm.moduleName [ "TnGql", "Object" ]) objectName [ dataType ]
    in
    { annotation = typeAnnotation
    }


decodeScalar : String -> Wrapped -> Elm.Expression
decodeScalar scalarName nullable =
    let
        lowered =
            String.toLower scalarName
    in
    case lowered of
        "string" ->
            Json.string

        "int" ->
            Json.int

        "float" ->
            Json.float

        "id" ->
            Engine.decodeId

        "boolean" ->
            Json.bool

        _ ->
            Elm.valueFrom (Elm.moduleName [ "Scalar" ]) (Utils.String.formatValue scalarName)
                |> Elm.get "decoder"


generateFiles : GraphQL.Schema.Schema -> List Elm.File
generateFiles graphQLSchema =
    let
        objects =
            graphQLSchema.objects
                |> Dict.toList
                |> List.map Tuple.second

        --|> List.filter (\object -> object.name == "App")
        objectFiles =
            objects
                |> List.map objectToModule

        phantomTypeDeclarations =
            objects
                |> List.map
                    (\object ->
                        Elm.customType object.name [ ( object.name, [] ) ]
                    )

        masterObjectFile =
            Elm.file (Elm.moduleName [ "TnGql", "Object" ])
                "These are all the types we need to protect our API using phantom types."
                (phantomTypeDeclarations
                    |> List.map Elm.expose
                )
    in
    masterObjectFile :: objectFiles
