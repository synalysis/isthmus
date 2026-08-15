module Pages.Reticulum exposing (Model, Msg, page)

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
import Tailwind.Theme exposing (buoy, ink_soft, s0, s4, s5, s6, s10)
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
    { title = "Reticulum"
    , body =
        [ Ui.pageHero "Reticulum / LXMF"
            "A cryptography-first mesh stack that runs over almost any link — and LXMF messaging that clients can aim at Isthmus destinations."
        , Ui.container []
            [ Ui.officialSite "https://reticulum.network" "reticulum.network"
            ]
        , Html.section
            [ classes [ Tw.pt s6, Tw.pb s10 ] ]
            [ Ui.container []
                [ Ui.prose
                    [ Html.h2 [] [ Html.text "What it is" ]
                    , Html.p []
                        [ Html.text "Reticulum (RNS) is a networking stack built around identity and encryption rather than IP addresses and DNS. Nodes generate their own keys; addressing is cryptographic; multi-hop transport autoconfigures across links that can be extremely slow or lossy. The same stack can ride LoRa, packet radio, serial, TCP/IP, I2P, and other interfaces — often several at once."
                        ]
                    , Html.p []
                        [ Html.text "LXMF (Lightweight Extensible Message Format) is the messaging protocol on top of Reticulum: end-to-end encrypted, delay-tolerant delivery with optional store-and-forward via propagation nodes. If Reticulum is the pipes, LXMF is how people write letters through them."
                        ]
                    , Html.h2 [] [ Html.text "History" ]
                    , Html.p []
                        [ Html.text "Reticulum was created by Mark Qvist; the protocol was dedicated to the public domain in 2016, with the Python reference implementation defining behaviour as it evolved. The stack and surrounding tools (Nomad Network, Sideband, LXMF, and a growing client ecosystem) target sovereign and off-grid use: networks you can stand up without a telco or cloud account. Development continues in the open-source community around the reference code and manual."
                        ]
                    , Html.p []
                        [ Html.text "Start from the official overview: "
                        , Html.a
                            [ Attr.href "https://reticulum.network"
                            , Attr.target "_blank"
                            , Attr.rel "noopener noreferrer"
                            ]
                            [ Html.text "reticulum.network" ]
                        , Html.text " and the "
                        , Html.a
                            [ Attr.href "https://github.com/markqvist/Reticulum"
                            , Attr.target "_blank"
                            , Attr.rel "noopener noreferrer"
                            ]
                            [ Html.text "reference repository" ]
                        , Html.text "."
                        ]
                    , Html.h2 [] [ Html.text "Use cases" ]
                    , Html.ul []
                        [ Html.li [] [ Html.text "Encrypted mesh messaging across mixed transports (radio + IP) without a central server" ]
                        , Html.li [] [ Html.text "Delay-tolerant delivery when peers are offline — propagation nodes hold mail until paths return" ]
                        , Html.li [] [ Html.text "Portable identities — your destination hash travels with you across interfaces" ]
                        , Html.li [] [ Html.text "Applications beyond chat: pages, files, and voice stacks built on the same plumbing" ]
                        ]
                    , Html.h2 [] [ Html.text "On Isthmus" ]
                    , Html.p []
                        [ Html.text "Isthmus runs its "
                        , Html.strong [] [ Html.text "own" ]
                        , Html.text " RNS + LXMF stack in a Python sidecar (config under "
                        , Html.code [] [ Html.text "~/.isthmus/reticulum" ]
                        , Html.text " by default). Registration and proxies mint real "
                        , Html.code [] [ Html.text "lxmf.delivery" ]
                        , Html.text " destinations. Clients such as MeshChatX, Sideband, or NomadNet can "
                        , Html.strong [] [ Html.text "send to and receive from" ]
                        , Html.text " those destinations like any other LXMF peer — share the hash or QR from "
                        , Html.code [] [ Html.text "/me" ]
                        , Html.text "."
                        ]
                    , Html.ul []
                        [ Html.li [] [ Html.text "Reticulum as primary — mint Nostr and MeshCore proxies for DMs" ]
                        , Html.li [] [ Html.text "Attach an LXMF destination to a bridge group — fan-out without minting keys for that member (including Meshtastic / MeshCore channel legs)" ]
                        , Html.li [] [ Html.text "Optional opaque RNS tunnels when you need transport, not only DMs" ]
                        ]
                    , Html.h2 [] [ Html.text "Running the sidecar" ]
                    , Html.p []
                        [ Html.text "Install "
                        , Html.code [] [ Html.text "pip install -r sidecar/requirements.txt" ]
                        , Html.text ", start Isthmus, and confirm Reticulum shows "
                        , Html.code [] [ Html.text "live" ]
                        , Html.text " under Admin → Networks. Give the Isthmus node AutoInterface or TCP reachability on your mesh, then message the minted destination from your LXMF client."
                        ]
                    , callout
                        [ Html.p [ classes [ Tw.m s0 ] ]
                            [ Html.text "Operator details: "
                            , Docs.reticulum "Reticulum guide"
                            , Html.text " and "
                            , Docs.registrationAndBridges "registration and bridges"
                            , Html.text "."
                            ]
                        ]
                    , Html.p [ classes [ Tw.mt s6 ] ]
                        [ Html.a [ Route.Path.href Route.Path.SelfHost ] [ Html.text "Self-host the sidecar →" ]
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
