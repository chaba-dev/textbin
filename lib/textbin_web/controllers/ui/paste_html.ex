defmodule TextbinWeb.UI.PasteHTML do
  @moduledoc """
  This module contains pages rendered by PasteController.

  See the `page_html` directory for all templates available.
  """
  use TextbinWeb, :html

  embed_templates "paste_html/*"
end
