module Layouts.Default exposing (Model, Msg, Props, layout)

import Effect exposing (Effect)
import Html exposing (Html)
import Html.Attributes as Attr
import Layout exposing (Layout)
import Route exposing (Route)
import Route.Path
import Shared
import Svg
import Svg.Attributes as SvgAttr
import Tailwind as Tw exposing (classes)
import Tailwind.Breakpoints exposing (hover, md)
import Tailwind.Theme exposing
    ( foam
    , ink
    , ink_soft
    , s0
    , s1
    , s2
    , s2_dot_5
    , s3
    , s4
    , s5
    , s8
    , s16
    , sea
    , stone
    )
import View exposing (View)


type alias Props =
    {}


layout : Props -> Shared.Model -> Route () -> Layout () Model Msg contentMsg
layout _ _ route =
    Layout.new
        { init = init
        , update = update
        , view = view route
        , subscriptions = subscriptions
        }



-- MODEL


type alias Model =
    {}


init : () -> ( Model, Effect Msg )
init _ =
    ( {}
    , Effect.none
    )



-- UPDATE


type Msg
    = NoOp


update : Msg -> Model -> ( Model, Effect Msg )
update msg model =
    case msg of
        NoOp ->
            ( model
            , Effect.none
            )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none



-- VIEW


view : Route () -> { toContentMsg : Msg -> contentMsg, content : View contentMsg, model : Model } -> View contentMsg
view route { content } =
    { title =
        if String.isEmpty content.title then
            "Isthmus"

        else
            content.title ++ " · Isthmus"
    , body =
        [ Html.div
            [ classes [ Tw.min_h_screen, Tw.flex, Tw.flex_col ] ]
            [ skipLink
            , siteHeader route.path
            , Html.main_ [ Attr.id "main", classes [ Tw.flex_1 ] ] content.body
            , siteFooter
            ]
        ]
    }


skipLink : Html msg
skipLink =
    Html.a
        [ Attr.href "#main"
        , classes
            [ Tw.absolute
            , Tw.left s4
            , Tw.raw "-top-16 z-40"
            , Tw.px s4
            , Tw.py s2_dot_5
            , Tw.rounded_md
            , Tw.bg_simple ink
            , Tw.text_simple foam
            , Tw.raw "focus:top-4"
            ]
        ]
        [ Html.text "Skip to content" ]


siteHeader : Route.Path.Path -> Html msg
siteHeader current =
    Html.header
        [ classes
            [ Tw.sticky
            , Tw.top s0
            , Tw.z_20
            , Tw.border_b
            , Tw.raw "border-ink/15 bg-foam/80 backdrop-blur-md"
            ]
        ]
        [ Html.div
            [ classes
                [ Tw.mx_auto
                , Tw.w_full
                , Tw.raw "max-w-[68rem]"
                , Tw.px s4
                , md [ Tw.px s8 ]
                , Tw.min_h s16
                , Tw.flex
                , Tw.flex_col
                , Tw.items_start
                , Tw.justify_between
                , Tw.gap s4
                , Tw.py s3
                , md
                    [ Tw.flex_row
                    , Tw.items_center
                    , Tw.py s0
                    ]
                ]
            ]
            [ Html.a
                [ Route.Path.href Route.Path.Home_
                , classes
                    [ Tw.inline_flex
                    , Tw.items_center
                    , Tw.gap s3
                    , Tw.no_underline
                    , Tw.text_simple ink
                    ]
                ]
                [ brandMark
                , Html.span
                    [ classes
                        [ Tw.font_display
                        , Tw.font_semibold
                        , Tw.tracking_tight
                        , Tw.raw "text-[1.55rem] leading-none"
                        ]
                    ]
                    [ Html.text "Isthmus" ]
                ]
            , Html.nav
                [ Attr.attribute "aria-label" "Primary"
                , classes
                    [ Tw.flex
                    , Tw.flex_wrap
                    , Tw.items_center
                    , Tw.gap_x s5
                    , Tw.gap_y s2
                    ]
                ]
                [ navLink current Route.Path.HowItWorks "How it works"
                , navLink current Route.Path.Meshcore "MeshCore"
                , navLink current Route.Path.Meshtastic "Meshtastic"
                , navLink current Route.Path.Reticulum "Reticulum"
                , navLink current Route.Path.Nostr "Nostr"
                , Html.a
                    [ Route.Path.href Route.Path.SelfHost
                    , classes
                        [ Tw.ml s1
                        , Tw.px s4
                        , Tw.py s2
                        , Tw.rounded_md
                        , Tw.bg_simple ink
                        , Tw.text_simple foam
                        , Tw.font_medium
                        , Tw.no_underline
                        , Tw.text_sm
                        , Tw.transition_colors
                        , Tw.duration_200
                        , hover
                            [ Tw.bg_simple sea
                            , Tw.raw "-translate-y-px"
                            ]
                        ]
                    ]
                    [ Html.text "Self-host" ]
                ]
            ]
        ]


navLink : Route.Path.Path -> Route.Path.Path -> String -> Html msg
navLink current path label =
    let
        active =
            current == path
    in
    Html.a
        [ Route.Path.href path
        , classes
            [ Tw.relative
            , Tw.py s1
            , Tw.text_sm
            , Tw.font_medium
            , Tw.no_underline
            , if active then
                Tw.text_simple ink

              else
                Tw.text_simple ink_soft
            , Tw.raw "after:absolute after:left-0 after:-bottom-0.5 after:h-0.5 after:w-full after:origin-left after:scale-x-0 after:bg-buoy after:transition-transform after:duration-200 hover:after:scale-x-100"
            , if active then
                Tw.raw "after:scale-x-100"

              else
                Tw.raw ""
            ]
        ]
        [ Html.text label ]


siteFooter : Html msg
siteFooter =
    Html.footer
        [ classes
            [ Tw.border_t
            , Tw.raw "border-ink/15 bg-foam/70"
            , Tw.py s8
            ]
        ]
        [ Html.div
            [ classes
                [ Tw.mx_auto
                , Tw.w_full
                , Tw.raw "max-w-[68rem]"
                , Tw.px s4
                , md [ Tw.px s8 ]
                , Tw.flex
                , Tw.flex_wrap
                , Tw.justify_between
                , Tw.gap s4
                , Tw.text_sm
                , Tw.text_simple stone
                ]
            ]
            [ Html.p [ classes [ Tw.m s0 ] ]
                [ Html.text "Direct messages across "
                , Html.strong [ classes [ Tw.font_display, Tw.font_semibold, Tw.text_simple ink ] ] [ Html.text "MeshCore" ]
                , Html.text ", "
                , Html.strong [ classes [ Tw.font_display, Tw.font_semibold, Tw.text_simple ink ] ] [ Html.text "Meshtastic" ]
                , Html.text ", "
                , Html.strong [ classes [ Tw.font_display, Tw.font_semibold, Tw.text_simple ink ] ] [ Html.text "Reticulum" ]
                , Html.text ", and "
                , Html.strong [ classes [ Tw.font_display, Tw.font_semibold, Tw.text_simple ink ] ] [ Html.text "Nostr" ]
                , Html.text "."
                ]
            , Html.p [ classes [ Tw.m s0 ] ]
                [ Html.a [ Attr.href "https://github.com/synalysis/isthmus" ] [ Html.text "GitHub" ]
                , Html.text " · "
                , Html.a [ Attr.href "mailto:hello@isthmus.channel" ] [ Html.text "hello@isthmus.channel" ]
                ]
            ]
        ]


brandMark : Html msg
brandMark =
    Svg.svg
        [ SvgAttr.viewBox "0 0 64 64"
        , -- Svg must use Svg.Attributes.class; Html.Attributes.class / Tw.classes set className and crash.
          SvgAttr.class "h-8 w-8 shrink-0"
        , Attr.attribute "aria-hidden" "true"
        ]
        [ Svg.rect
            [ SvgAttr.width "64"
            , SvgAttr.height "64"
            , SvgAttr.rx "12"
            , SvgAttr.fill "#0B3D4A"
            ]
            []
        , Svg.path
            [ SvgAttr.d "M8 38c8-10 16-10 24 0s16 10 24 0"
            , SvgAttr.fill "none"
            , SvgAttr.stroke "#7EB8B2"
            , SvgAttr.strokeWidth "3"
            , SvgAttr.strokeLinecap "round"
            ]
            []
        , Svg.path
            [ SvgAttr.d "M8 26c8 10 16 10 24 0s16-10 24 0"
            , SvgAttr.fill "none"
            , SvgAttr.stroke "#D9783A"
            , SvgAttr.strokeWidth "3"
            , SvgAttr.strokeLinecap "round"
            ]
            []
        , Svg.circle
            [ SvgAttr.cx "32"
            , SvgAttr.cy "32"
            , SvgAttr.r "4.5"
            , SvgAttr.fill "#F4F7F5"
            ]
            []
        ]
