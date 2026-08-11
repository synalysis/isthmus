module Components.HeroCanvas exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Svg
import Svg.Attributes as SvgAttr


view : Html msg
view =
    Html.div [ Attr.class "hero-canvas", Attr.attribute "aria-hidden" "true" ]
        [ Svg.svg
            [ SvgAttr.viewBox "0 0 1440 900"
            , SvgAttr.preserveAspectRatio "xMidYMid slice"
            , SvgAttr.class "hero-drift"
            ]
            [ Svg.defs []
                [ Svg.linearGradient
                    [ SvgAttr.id "water"
                    , SvgAttr.x1 "0%"
                    , SvgAttr.y1 "0%"
                    , SvgAttr.x2 "100%"
                    , SvgAttr.y2 "100%"
                    ]
                    [ Svg.stop [ SvgAttr.offset "0%", SvgAttr.stopColor "#c9e3df" ] []
                    , Svg.stop [ SvgAttr.offset "55%", SvgAttr.stopColor "#8ebdb8" ] []
                    , Svg.stop [ SvgAttr.offset "100%", SvgAttr.stopColor "#4f8f8c" ] []
                    ]
                , Svg.linearGradient
                    [ SvgAttr.id "land"
                    , SvgAttr.x1 "0%"
                    , SvgAttr.y1 "0%"
                    , SvgAttr.x2 "0%"
                    , SvgAttr.y2 "100%"
                    ]
                    [ Svg.stop [ SvgAttr.offset "0%", SvgAttr.stopColor "#dfe8d8" ] []
                    , Svg.stop [ SvgAttr.offset "100%", SvgAttr.stopColor "#a8b89a" ] []
                    ]
                ]
            , Svg.rect
                [ SvgAttr.width "1440"
                , SvgAttr.height "900"
                , SvgAttr.fill "url(#water)"
                ]
                []
            , contour "M-40 210 C 220 160, 380 260, 620 210 S 980 120, 1500 190" "#0b3d4a" "0.12"
            , contour "M-40 310 C 260 250, 420 360, 700 300 S 1080 220, 1500 310" "#0b3d4a" "0.1"
            , contour "M-40 430 C 280 390, 460 500, 760 430 S 1120 360, 1500 450" "#0b3d4a" "0.08"
            , Svg.path
                [ SvgAttr.d "M520 120 C 560 220, 575 320, 590 455 C 610 620, 640 720, 690 860 L 890 860 C 860 700, 830 560, 820 420 C 810 290, 840 180, 900 90 L 720 90 C 650 90, 560 90, 520 120 Z"
                , SvgAttr.fill "url(#land)"
                , SvgAttr.opacity "0.95"
                ]
                []
            , Svg.path
                [ SvgAttr.d "M590 455 C 640 470, 760 470, 820 420"
                , SvgAttr.fill "none"
                , SvgAttr.stroke "#d9783a"
                , SvgAttr.strokeWidth "10"
                , SvgAttr.strokeLinecap "round"
                ]
                []
            , node 590 455
            , node 820 420
            , Svg.circle
                [ SvgAttr.cx "705"
                , SvgAttr.cy "445"
                , SvgAttr.r "42"
                , SvgAttr.fill "none"
                , SvgAttr.stroke "#0b3d4a"
                , SvgAttr.strokeWidth "2"
                , SvgAttr.opacity "0.35"
                , SvgAttr.class "hero-pulse"
                ]
                []
            , Svg.circle
                [ SvgAttr.cx "705"
                , SvgAttr.cy "445"
                , SvgAttr.r "8"
                , SvgAttr.fill "#0b3d4a"
                ]
                []
            , signal 420 300 590 455
            , signal 980 280 820 420
            , signal 300 560 590 455
            , signal 1100 560 820 420
            ]
        ]


contour : String -> String -> String -> Svg.Svg msg
contour d color opacity =
    Svg.path
        [ SvgAttr.d d
        , SvgAttr.fill "none"
        , SvgAttr.stroke color
        , SvgAttr.strokeWidth "1.5"
        , SvgAttr.opacity opacity
        ]
        []


node : Float -> Float -> Svg.Svg msg
node x y =
    Svg.circle
        [ SvgAttr.cx (String.fromFloat x)
        , SvgAttr.cy (String.fromFloat y)
        , SvgAttr.r "7"
        , SvgAttr.fill "#f4f7f5"
        , SvgAttr.stroke "#0b3d4a"
        , SvgAttr.strokeWidth "3"
        ]
        []


signal : Float -> Float -> Float -> Float -> Svg.Svg msg
signal x1 y1 x2 y2 =
    Svg.line
        [ SvgAttr.x1 (String.fromFloat x1)
        , SvgAttr.y1 (String.fromFloat y1)
        , SvgAttr.x2 (String.fromFloat x2)
        , SvgAttr.y2 (String.fromFloat y2)
        , SvgAttr.stroke "#0b3d4a"
        , SvgAttr.strokeWidth "1.5"
        , SvgAttr.strokeDasharray "4 7"
        , SvgAttr.opacity "0.35"
        ]
        []
