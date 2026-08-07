defmodule IsthmusWeb.PageController do
  use IsthmusWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
