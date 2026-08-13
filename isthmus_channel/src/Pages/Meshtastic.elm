module Pages.Meshtastic exposing (Model, Msg, page)

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
    { title = "Meshtastic"
    , body =
        [ Ui.pageHero "Meshtastic"
            "A popular LoRa mesh for hikers and neighbourhoods — Isthmus plugs in via USB companion radios and joins private channels to bridge groups."
        , Ui.container []
            [ Ui.officialSite "https://meshtastic.org" "meshtastic.org"
            ]
        , Html.section
            [ classes [ Tw.pt s6, Tw.pb s10 ] ]
            [ Ui.container []
                [ Ui.prose
                    [ Html.h2 [] [ Html.text "What it is" ]
                    , Html.p []
                        [ Html.text "Meshtastic is an open LoRa mesh for off-grid text. Phones talk to a small radio (USB or Bluetooth); the radios flood messages across the mesh using shared "
                        , Html.strong [] [ Html.text "channels" ]
                        , Html.text " — a name plus a pre-shared key. Slot 0 is the primary channel and sets the radio frequency; slots 1–7 are extra private channels on the same modem settings."
                        ]
                    , Html.h2 [] [ Html.text "History" ]
                    , Html.p []
                        [ Html.text "The project started around 2020 (Geeksville / Kevin Hester and contributors) as a simple hiker mesh on cheap ESP32 + LoRa boards. Firmware, phone apps, and a large hobbyist community grew around "
                        , Html.a
                            [ Attr.href "https://meshtastic.org"
                            , Attr.target "_blank"
                            , Attr.rel "noopener noreferrer"
                            ]
                            [ Html.text "meshtastic.org" ]
                        , Html.text ". Many operators already have a node; Isthmus does not replace those clients — it sits beside them."
                        ]
                    , Html.h2 [] [ Html.text "Who uses it" ]
                    , Html.ul []
                        [ Html.li [] [ Html.text "Trail and event messaging when there is no cell coverage" ]
                        , Html.li [] [ Html.text "Neighbourhood and club meshes with a handful of solar nodes" ]
                        , Html.li [] [ Html.text "People who already own Meshtastic hardware and want it to reach MeshCore, LXMF, or Nostr" ]
                        ]
                    , Html.h2 [] [ Html.text "On Isthmus: companion channels" ]
                    , Html.p []
                        [ Html.text "Plug in a stock Meshtastic companion over "
                        , Html.strong [] [ Html.text "USB serial" ]
                        , Html.text ". Isthmus auto-detects it (after MeshCore probes), or you can pin "
                        , Html.code [] [ Html.text "ISTHMUS_MESHTASTIC_PORT" ]
                        , Html.text ". Several radios can be attached at once; Admin → Meshtastic shows each one, LoRa region / modem, and the channel table."
                        ]
                    , Html.p []
                        [ Html.text "Link a "
                        , Html.strong [] [ Html.text "private secondary slot (1–7)" ]
                        , Html.text " to a bridge group. Inbound channel texts fan out to Nostr, MeshCore, and Reticulum members; traffic the other way is posted back onto each linked Meshtastic radio. Other Meshtastic devices join with the usual invite URL ("
                        , Html.code [] [ Html.text "https://meshtastic.org/e/#…" ]
                        , Html.text "). Same model as MeshCore companion channels."
                        ]
                    , callout
                        [ Html.p [ classes [ Tw.m s0, Tw.mb s3 ] ]
                            [ Html.strong [ classes [ Tw.text_simple ink ] ] [ Html.text "What this is not. " ]
                            , Html.text "Isthmus does not yet attach Meshtastic node ids as DM / identity legs, and it does not run MeshCore-style whole-packet island tunnels on Meshtastic radios. Stay on channel ↔ group bridging until those land. Bluetooth companions are not wired up — USB only."
                            ]
                        , Html.p [ classes [ Tw.m s0 ] ]
                            [ Html.strong [ classes [ Tw.text_simple ink ] ] [ Html.text "Ask first. " ]
                            , Html.text "Bridging a Meshtastic channel onto other networks (or the internet) mixes communities and airtime. Do not do it where the local mesh does not want an off-mesh gateway."
                            ]
                        ]
                    , Html.p []
                        [ Html.text "Operator details: "
                        , Docs.meshtasticAdapter "Meshtastic adapter guide"
                        , Html.text ". Groups and fan-out: "
                        , Docs.registrationAndBridges "registration and bridges"
                        , Html.text "."
                        ]
                    , Html.p [ classes [ Tw.mt s6 ] ]
                        [ Html.a [ Route.Path.href Route.Path.SelfHost ] [ Html.text "Self-host with Meshtastic hardware →" ]
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
