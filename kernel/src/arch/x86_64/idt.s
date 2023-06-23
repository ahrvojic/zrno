.global load_idt
.type load_idt, @function
load_idt:
    lidt (idtr)
    ret
