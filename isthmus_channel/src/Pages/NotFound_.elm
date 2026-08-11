module Pages.NotFound_ exposing (Model, Msg, page)

import Components.Ui as Ui
import Effect exposing (Effect)
import Html
import Layouts
import Page exposing (Page)
import Route exposing (Route)
import Route.Path
import Shared
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
    { title = "Not found"
    , body =
        [ Ui.section
            [ Ui.kicker "404"
            , Ui.sectionTitle "This path washes out."
            , Ui.sectionLede "That URL isn’t on the chart. Head back to the channel entrance."
            , Ui.btnPrimary [ Route.Path.href Route.Path.Home_ ] [ Html.text "Back to Isthmus" ]
            ]
        ]
    }
