all: zx200a.bin

%.bin: %.p
	p2bin -r 0-2047 $< $@

%.hex: %.p
	p2hex -F Intel -r 0-2047 $< $@

%.lst %.p: %.asm
	rm -f $*.lst
	asl -cpu 8085 -L -C $<
	chmod -w $*.lst
