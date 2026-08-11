module Pages.Meshcore exposing (Model, Msg, page)

import Components.Contact as Contact
import Components.Docs as Docs
import Components.Ui as Ui
import Effect exposing (Effect)
import Html
import Html.Attributes as Attr
import Layouts
import Page exposing (Page)
import Route exposing (Route)
import Route.Path
import Shared
import Tailwind as Tw exposing (classes)
import Tailwind.Theme exposing (buoy, ink, ink_soft, s0, s3, s4, s5, s6, s10)
import View exposing (View)


page : Shared.Model -> Route () -> Page Model Msg
page _ _ =
    Page.new
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }
        |> Page.withLayout toLayout


toLayout : Model -> Layouts.Layout Msg
toLayout _ =
    Layouts.Default {}


type alias Model =
    {}


init : () -> ( Model, Effect Msg )
init () =
    ( {}, Effect.none )


type Msg
    = NoOp


update : Msg -> Model -> ( Model, Effect Msg )
update msg model =
    case msg of
        NoOp ->
            ( model, Effect.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none


view : Model -> View Msg
view _ =
    { title = "MeshCore"
    , body =
        [ Ui.pageHero "MeshCore"
            "A LoRa mesh built for roles: companions that talk, repeaters that route — and, with the right firmware, islands that join through Isthmus."
        , Ui.container []
            [ Ui.officialSite "https://meshcore.io" "meshcore.io"
            ]
        , Html.section
            [ classes [ Tw.pt s6, Tw.pb s10 ] ]
            [ Ui.container []
                [ Ui.prose
                    [ Html.h2 [] [ Html.text "What it is" ]
                    , Html.p []
                        [ Html.text "MeshCore is an open, LoRa-based mesh for low-power text messaging when cellular and Wi‑Fi are gone or never arrived. Nodes speak a compact packet protocol over unlicensed sub‑GHz radios (the same class of ESP32 + SX126x boards many operators already own). Clients connect with phone or web apps; infrastructure nodes stay on the air as repeaters and room servers."
                        ]
                    , Html.h2 [] [ Html.text "History" ]
                    , Html.p []
                        [ Html.text "Australian developer Scott Powell (Ripple Radios) began the protocol in late 2024. In early 2025 the project launched more broadly with collaborators including Liam Cottle (mobile/web clients) and others in the UK and NZ — shaped in part by real disaster-comms needs after events like Cyclone Gabrielle. The firmware lives under the MIT license on "
                        , Html.a
                            [ Attr.href "https://github.com/meshcore-dev/MeshCore"
                            , Attr.target "_blank"
                            , Attr.rel "noopener noreferrer"
                            ]
                            [ Html.text "meshcore-dev/MeshCore" ]
                        , Html.text "; docs and community gather around "
                        , Html.a
                            [ Attr.href "https://meshcore.io"
                            , Attr.target "_blank"
                            , Attr.rel "noopener noreferrer"
                            ]
                            [ Html.text "meshcore.io" ]
                        , Html.text "."
                        ]
                    , Html.h2 [] [ Html.text "Design idea" ]
                    , Html.p []
                        [ Html.text "MeshCore separates "
                        , Html.strong [] [ Html.text "roles" ]
                        , Html.text ". Companion radios are the user’s endpoint — they do not flood-repeat for the whole mesh. Repeaters and room servers form the always-on backbone, learn paths, and carry multi-hop traffic. Routing starts with discovery, then prefers learned paths so airtime stays usable as the network grows. That specialization is the point: battery clients stay light; infrastructure carries the load."
                        ]
                    , Html.h2 [] [ Html.text "Who uses it" ]
                    , Html.ul []
                        [ Html.li [] [ Html.text "Off-grid and trail messaging — DMs and shared channels without a cell tower" ]
                        , Html.li [] [ Html.text "Neighbourhood or event meshes — a handful of solar repeaters plus phones on companions" ]
                        , Html.li [] [ Html.text "Emergency / backup text when internet and cellular fail" ]
                        , Html.li [] [ Html.text "Experimenters bridging RF islands that sit on different frequencies or hills" ]
                        ]
                    , Html.h2 [] [ Html.text "On Isthmus: two different jobs" ]
                    , Html.p []
                        [ Html.text "Isthmus talks to MeshCore in two ways. Don’t confuse them:"
                        ]
                    , Html.h2 [] [ Html.text "1. Companion gateway (messages)" ]
                    , Html.p []
                        [ Html.text "A stock "
                        , Html.strong [] [ Html.text "companion" ]
                        , Html.text " over USB is enough for the identity gateway: sync contacts and channels, register MeshCore as primary, attach real contacts to bridge groups, and fan DMs out to Nostr / LXMF. (BLE companion transport is not wired up in Isthmus yet.) One companion is one RF inbox — when several groups share it, address traffic with an "
                        , Html.code [] [ Html.text "@token" ]
                        , Html.text "."
                        ]
                    , Html.h2 [] [ Html.text "2. Tunnels / island bridges (raw packets)" ]
                    , Html.p []
                        [ Html.text "Joining two MeshCore islands so they behave as "
                        , Html.strong [] [ Html.text "one mesh" ]
                        , Html.text " — adverts, path discovery, ACKs, the lot — is a tunnel payload. That "
                        , Html.strong [] [ Html.text "cannot" ]
                        , Html.text " be done with a normal companion: the companion protocol only surfaces traffic addressed to you, and its raw-send path wraps data as your own app packet instead of replaying the original "
                        , Html.code [] [ Html.text "mesh::Packet" ]
                        , Html.text "."
                        ]
                    , callout
                        [ Html.p [ classes [ Tw.m s0, Tw.mb s3 ] ]
                            [ Html.strong [ classes [ Tw.text_simple ink ] ] [ Html.text "Bridge firmware required. " ]
                            , Html.text "Each island needs a MeshCore "
                            , Html.strong [] [ Html.text "repeater (or bridge-capable) device" ]
                            , Html.text " flashed with firmware built for the RS232/USB packet bridge (e.g. "
                            , Html.code [] [ Html.text "WITH_RS232_BRIDGE" ]
                            , Html.text "). Upstream does not ship prebuilt bridge binaries for every board — you build and flash them. Isthmus then owns the packet CDC/serial port and tunnels frames between islands. Stock companion firmware is not enough for this path."
                            ]
                        , Html.p [ classes [ Tw.m s0, Tw.mb s3 ] ]
                            [ Html.strong [ classes [ Tw.text_simple ink ] ] [ Html.text "E2E on tunnels. " ]
                            , Html.text "Island-bridge tunnels forward opaque packets; message content stays end-to-end encrypted between MeshCore endpoints. That is unlike registration/bridge "
                            , Html.strong [] [ Html.text "groups" ]
                            , Html.text ", where Isthmus must decrypt and re-encrypt to translate — those gateways belong on machines you fully control, not a shared VPS."
                            ]
                        , Html.p [ classes [ Tw.m s0 ] ]
                            [ Html.strong [ classes [ Tw.text_simple ink ] ] [ Html.text "Ask first. " ]
                            , Html.text "Do not install an internet tunnel on a MeshCore mesh whose community does not want one. Many operators keep their island on RF only; bridging it over IP mixes regions and airtime they did not agree to share."
                            ]
                        ]
                    , Html.p []
                        [ Html.text "Copy-pasteable "
                        , Docs.meshcoreBridgeFirmwareBuild "build and flash steps"
                        , Html.text ". Design notes: "
                        , Docs.meshcoreIslandBridge "island bridge guide"
                        , Html.text "."
                        ]
                    , Html.p [ classes [ Tw.mt s6 ] ]
                        [ Html.a [ Route.Path.href Route.Path.SelfHost ] [ Html.text "Self-host with MeshCore hardware →" ]
                        , Html.text " · "
                        , Html.a [ Route.Path.href Route.Path.Networks ] [ Html.text "All networks" ]
                        ]
                    ]
                ]
            ]
        , Contact.viewBand
        ]
    }


callout : List (Html.Html msg) -> Html.Html msg
callout children =
    Html.div
        [ classes
            [ Tw.mt s6
            , Tw.px s5
            , Tw.py s4
            , Tw.border_l_4
            , Tw.border_simple buoy
            , Tw.raw "bg-buoy/10"
            , Tw.text_simple ink_soft
            ]
        ]
        children
