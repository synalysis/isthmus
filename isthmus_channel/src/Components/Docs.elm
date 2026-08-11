module Components.Docs exposing
    ( meshcoreBridgeFirmwareBuild
    , meshcoreIslandBridge
    , registrationAndBridges
    , reticulum
    )

import Html exposing (Html)
import Html.Attributes as Attr


githubBlob : String -> String
githubBlob path =
    "https://github.com/synalysis/isthmus/blob/main/" ++ path


link : String -> String -> Html msg
link path label =
    Html.a
        [ Attr.href (githubBlob path)
        , Attr.target "_blank"
        , Attr.rel "noopener noreferrer"
        ]
        [ Html.text label ]


meshcoreBridgeFirmwareBuild : String -> Html msg
meshcoreBridgeFirmwareBuild label =
    link "docs/guides/meshcore_bridge_firmware_build.md" label


meshcoreIslandBridge : String -> Html msg
meshcoreIslandBridge label =
    link "docs/guides/meshcore_island_bridge.md" label


reticulum : String -> Html msg
reticulum label =
    link "docs/guides/reticulum.md" label


registrationAndBridges : String -> Html msg
registrationAndBridges label =
    link "docs/guides/registration_and_bridges.md" label
