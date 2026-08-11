module Pages.HowItWorks exposing (Model, Msg, page)

import Components.Contact as Contact
import Components.Ui as Ui
import Effect exposing (Effect)
import Html
import Layouts
import Page exposing (Page)
import Route exposing (Route)
import Route.Path
import Shared
import Tailwind as Tw exposing (classes)
import Tailwind.Theme exposing (buoy, ink, ink_soft, s0, s1, s3, s4, s5, s6, s10, stone)
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
    { title = "How it works"
    , body =
        [ Ui.pageHero "How it works"
            "An isthmus is a strip of land joining two larger shores. This gateway does the same for networks that were never designed to meet."
        , Html.section
            [ classes [ Tw.pt s6, Tw.pb s10 ] ]
            [ Ui.container []
                [ Html.ol
                    [ classes
                        [ Tw.list_none
                        , Tw.m s0
                        , Tw.p s0
                        , Tw.border_t
                        , Tw.raw "border-ink/15"
                        ]
                    ]
                    [ step "01" "Transport tunnels" "Join same-protocol islands by carrying traffic over another network as the pipe. MeshCore island bridges replay whole packets — adverts, DMs, ACKs, path discovery — so the far side looks like ordinary mesh neighbours. Payloads stay end-to-end encrypted between the mesh endpoints; Isthmus forwards opaque frames and does not need to read message content."
                    , step "02" "Identity gateway" "Register a primary identity on one network. Isthmus mints trusted proxy identities on the others and fans messages through the gateway with vault-backed key material. Crossing protocol boundaries means the gateway must decrypt on the inbound leg and re-encrypt on the outbound ones."
                    , step "03" "Bridge groups" "When everyone already has working identities, attach them to a group. No minting — the gateway still decrypts and re-encrypts as it fans out among real members on Nostr, MeshCore, and Reticulum."
                    , step "04" "Operator surface" "NIP-07 sign-in, self-service registration with QR handoff, admin relays and policy, network health, and a forward log — Elixir/OTP + Phoenix under the hood."
                    ]
                , Html.div
                    [ classes
                        [ Tw.mt s6
                        , Tw.px s5
                        , Tw.py s4
                        , Tw.border_l_4
                        , Tw.border_simple buoy
                        , Tw.raw "bg-buoy/10"
                        ]
                    ]
                    [ Html.p
                        [ classes [ Tw.m s0, Tw.mb s3, Tw.text_simple ink_soft ] ]
                        [ Html.strong [ classes [ Tw.text_simple ink ] ] [ Html.text "Encryption and trust. " ]
                        , Html.text "Tunnels preserve end-to-end encryption for the carried traffic. Registration and bridge "
                        , Html.strong [] [ Html.text "groups" ]
                        , Html.text " cannot: Isthmus must see plaintext (or equivalent cleartext at the gateway) to translate between networks. That implies running gateway/group instances on machines "
                        , Html.strong [] [ Html.text "you fully control" ]
                        , Html.text " — a home box, colo you administer, or edge host next to the radios — not on a shared VPS or other host where the operator of the metal can read process memory, disks, or logs."
                        ]
                    , Html.p
                        [ classes [ Tw.m s0, Tw.text_simple ink_soft ] ]
                        [ Html.text "MeshCore companions are one RF inbox per USB radio. When several groups share a companion, address traffic with an "
                        , Html.code [] [ Html.text "@token" ]
                        , Html.text " (or rely on last-peer / single-group fallback)."
                        ]
                    ]
                , Html.p [ classes [ Tw.mt s6 ] ]
                    [ Html.a [ Route.Path.href Route.Path.Networks ] [ Html.text "See how each network fits →" ]
                    ]
                ]
            ]
        , Contact.viewBand
        ]
    }


step : String -> String -> String -> Html.Html msg
step index title body =
    Html.li
        [ classes
            [ Tw.grid
            , Tw.gap s4
            , Tw.py s5
            , Tw.border_b
            , Tw.raw "border-ink/15 grid-cols-[auto_1fr]"
            ]
        ]
        [ Html.span
            [ classes
                [ Tw.font_display
                , Tw.font_semibold
                , Tw.text_simple buoy
                , Tw.raw "text-[1.35rem] leading-tight"
                ]
            ]
            [ Html.text index ]
        , Html.div []
            [ Html.h3
                [ classes
                    [ Tw.font_display
                    , Tw.font_semibold
                    , Tw.m s0
                    , Tw.mb s1
                    , Tw.raw "text-[1.35rem] tracking-tight"
                    ]
                ]
                [ Html.text title ]
            , Html.p
                [ classes
                    [ Tw.m s0
                    , Tw.text_simple stone
                    , Tw.raw "max-w-[60ch]"
                    ]
                ]
                [ Html.text body ]
            ]
        ]
