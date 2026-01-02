#!/usr/bin/env python3
import os
import stat
from prompt_toolkit import Application
from prompt_toolkit.layout.containers import HSplit, VSplit, Window, WindowAlign, FloatContainer, Float
from prompt_toolkit.layout.layout import Layout
from prompt_toolkit.widgets import Frame, TextArea, Button
from prompt_toolkit.layout.controls import FormattedTextControl
from prompt_toolkit.key_binding import KeyBindings
from prompt_toolkit.styles import Style

ENV_FILE = ".panel.env"

def write_env_file(data):
    content = (
        f'PANEL_DOMAIN="{data["Domain"]}"\n'
        f'PANEL_USER="{data["User"]}"\n'
        f'PANEL_PASS="{data["Pass"]}"\n'
        f'PANEL_EMAIL="{data["Email"]}"\n'
    )
    with open(ENV_FILE, "w", encoding="utf-8") as f:
        f.write(content)
    os.chmod(ENV_FILE, stat.S_IRUSR | stat.S_IWUSR)

domain_input = TextArea(multiline=False)
user_input   = TextArea(multiline=False)
pass_input   = TextArea(multiline=False, password=True)
email_input  = TextArea(multiline=False)

def do_submit():
    write_env_file({
        "Domain": domain_input.text.strip(),
        "User": user_input.text.strip(),
        "Pass": pass_input.text,
        "Email": email_input.text.strip(),
    })
    app.exit()

submit_btn = Button("Submit", handler=do_submit)
exit_btn   = Button("Exit", handler=lambda: app.exit())

form_body = HSplit(
    [
        Frame(domain_input, title="Domain (e.g. panel.example.com)"),
        Window(height=1),
        Window(
            content=FormattedTextControl("Panel Account Creation"),
            height=1,
            align=WindowAlign.CENTER,
        ),
        Window(height=1, char="─"),
        Frame(user_input, title="Username"),
        Frame(pass_input, title="Password"),
        Frame(email_input, title="Email"),
        Window(height=1),
        VSplit([submit_btn, exit_btn], padding=4, align=WindowAlign.CENTER),
    ],
    width=60
)

root_container = FloatContainer(
    content=Window(),
    floats=[Float(content=Frame(form_body, title="Pterodactyl Installation"))],
)

kb = KeyBindings()
@kb.add("c-c")
@kb.add("escape")
def _(event): event.app.exit()

@kb.add("enter")
def _(event):
    if event.app.layout.has_focus(submit_btn): do_submit()
    elif event.app.layout.has_focus(exit_btn): app.exit()
    else: event.app.layout.focus_next()

@kb.add("down")
@kb.add("tab")
def _(event): event.app.layout.focus_next()

@kb.add("up")
@kb.add("s-tab")
def _(event): event.app.layout.focus_previous()

style = Style.from_dict({
    "frame.border": "#888888",
    "frame.label": "#ffffff bold",
    "button.focused": "bg:#ffffff #000000",
})

app = Application(
    layout=Layout(root_container, focused_element=domain_input),
    key_bindings=kb,
    style=style,
    full_screen=True,
)

if __name__ == "__main__":
    app.run()
