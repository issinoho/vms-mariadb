$! PROMPT_LF.COM - configure's prompts on a terminal (run it in an
$! interactive session).  A READ/PROMPT right after a message starts on a
$! new line; does it still when SET TERMINAL/NOECHO comes between them (as
$! for configure's password), and does a blank line written first fix it?
$ set noon
$ write sys$output "MSG-ONE plain prompt next"
$ read/end_of_file=done/prompt="PLAIN: " sys$command a
$ write sys$output "MSG-TWO noecho prompt next"
$ set terminal/noecho
$ read/end_of_file=done/prompt="SECRET1: " sys$command b
$ set terminal/echo
$ write sys$output "MSG-THREE blank line, then noecho prompt"
$ write sys$output ""
$ set terminal/noecho
$ read/end_of_file=done/prompt="SECRET2: " sys$command c
$ set terminal/echo
$done:
$ write sys$output "PROBE-END a=", a, " blen=", f$length(b), " clen=", f$length(c)
