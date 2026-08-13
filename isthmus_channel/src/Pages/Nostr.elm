module Pages.Nostr exposing (Model, Msg, page)

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
    { title = "Nostr"
    , body =
        [ Ui.pageHero "Nostr"
            "Notes and Other Stuff Transmitted by Relays — simple signed events, replaceable servers, and an identity you carry as a keypair."
        , Ui.container []
            [ Ui.officialSite "https://nostr.com" "nostr.com"
            ]
        , Html.section
            [ classes [ Tw.pt s6, Tw.pb s10 ] ]
            [ Ui.container []
                [ Ui.prose
                    [ Html.h2 [] [ Html.text "What it is" ]
                    , Html.p []
                        [ Html.text "Nostr is an open protocol for social and app data built from one idea: users are public keys, every update is a signed JSON "
                        , Html.strong [] [ Html.text "event" ]
                        , Html.text ", and "
                        , Html.strong [] [ Html.text "relays" ]
                        , Html.text " are interchangeable stores that clients publish to and fetch from. Relays do not have to talk to each other. If one bans you, your identity (the key) and your followers can follow you to another relay. Clients verify signatures; nothing is trusted because a server said so."
                        ]
                    , Html.h2 [] [ Html.text "History" ]
                    , Html.p []
                        [ Html.text "The protocol was sketched by the developer known as "
                        , Html.strong [] [ Html.text "fiatjaf" ]
                        , Html.text " in 2020 as a deliberately small alternative to federated and peer-to-peer social stacks that had grown complex or brittle. Early clients and relays proved the model; by 2022–2023 a wave of apps (and Bitcoin Lightning “zaps”) pushed it into wider use. Extensibility lives in "
                        , Html.strong [] [ Html.text "NIPs" ]
                        , Html.text " (Nostr Implementation Possibilities) — optional specs for DMs, profiles, auth, and more — so the core stays tiny while ecosystems grow."
                        ]
                    , Html.p []
                        [ Html.text "Official site: "
                        , Html.a
                            [ Attr.href "https://nostr.com"
                            , Attr.target "_blank"
                            , Attr.rel "noopener noreferrer"
                            ]
                            [ Html.text "nostr.com" ]
                        , Html.text ". Original pitch: "
                        , Html.a
                            [ Attr.href "https://fiatjaf.com/nostr.html"
                            , Attr.target "_blank"
                            , Attr.rel "noopener noreferrer"
                            ]
                            [ Html.text "fiatjaf.com/nostr.html" ]
                        , Html.text ". Living NIP set: "
                        , Html.a
                            [ Attr.href "https://github.com/nostr-protocol/nips"
                            , Attr.target "_blank"
                            , Attr.rel "noopener noreferrer"
                            ]
                            [ Html.text "nostr-protocol/nips" ]
                        , Html.text "."
                        ]
                    , Html.h2 [] [ Html.text "Use cases" ]
                    , Html.ul []
                        [ Html.li [] [ Html.text "Public notes and long-form — Twitter-like clients without a single company timeline" ]
                        , Html.li [] [ Html.text "Private DMs (NIP-04 / newer schemes) across relays you choose" ]
                        , Html.li [] [ Html.text "Login to web apps via NIP-07 — the browser extension holds the key and signs challenges" ]
                        , Html.li [] [ Html.text "Payments and zaps over Lightning, marketplaces, and other apps that reuse the same identity" ]
                        ]
                    , Html.h2 [] [ Html.text "On Isthmus" ]
                    , Html.p []
                        [ Html.text "Nostr is how operators "
                        , Html.strong [] [ Html.text "sign in" ]
                        , Html.text ", how admins are allowlisted ("
                        , Html.code [] [ Html.text "ISTHMUS_ADMIN_NPUBS" ]
                        , Html.text "), and a first-class messaging leg: DMs through a relay pool can cross into MeshCore, Meshtastic channels, and LXMF via registration or bridge groups."
                        ]
                    , Html.h2 [] [ Html.text "Login with a signer extension" ]
                    , Html.p []
                        [ Html.text "Isthmus never asks for your "
                        , Html.code [] [ Html.text "nsec" ]
                        , Html.text " in the browser. A NIP-07 extension such as "
                        , Html.a
                            [ Attr.href "https://chromewebstore.google.com/detail/aka-profiles/ncmflpbbagcnakkolfpcpogheckolnad"
                            , Attr.target "_blank"
                            , Attr.rel "noopener noreferrer"
                            ]
                            [ Html.text "AKA Profiles" ]
                        , Html.text " holds the key and signs challenges. Open "
                        , Html.code [] [ Html.text "/login" ]
                        , Html.text ", approve the request, and you’re in as that "
                        , Html.code [] [ Html.text "npub" ]
                        , Html.text "."
                        ]
                    , Html.h2 [] [ Html.text "Gateway roles" ]
                    , Html.ul []
                        [ Html.li [] [ Html.text "Nostr as primary — mint MeshCore contact + Reticulum LXMF destination proxies" ]
                        , Html.li [] [ Html.text "Attach an existing npub to a bridge group — no new keys for that member" ]
                        , Html.li [] [ Html.text "Admin allowlist — listed npubs unlock /admin" ]
                        ]
                    , Html.h2 [] [ Html.text "Relays and DMs" ]
                    , Html.p []
                        [ Html.text "Operators configure the relay pool in admin. Bridged traffic uses Nostr DMs where policy allows; see "
                        , Docs.registrationAndBridges "registration and bridges"
                        , Html.text " for delivery rules on proxy vs attached legs."
                        ]
                    , callout
                        [ Html.p [ classes [ Tw.m s0 ] ]
                            [ Html.text "New to keys? The "
                            , Html.a [ Route.Path.href Route.Path.SelfHost ] [ Html.text "self-host guide" ]
                            , Html.text " walks through creating an identity and signing in with AKA Profiles."
                            ]
                        ]
                    , Html.p [ classes [ Tw.mt s6 ] ]
                        [ Html.a [ Route.Path.href Route.Path.SelfHost ] [ Html.text "Create a key and log in →" ]
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
