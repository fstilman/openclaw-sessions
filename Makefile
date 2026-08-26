EMACS ?= emacs

.PHONY: test compile checkdoc package-lint clean

test:
	$(EMACS) -Q --batch -L . -L test \
	  -l test/openclaw-sessions-test.el \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile openclaw-sessions.el

checkdoc:
	$(EMACS) -Q --batch -L . \
	  --eval '(progn (require (quote checkdoc)) (checkdoc-file "openclaw-sessions.el"))'

package-lint:
	$(EMACS) -Q --batch -L . \
	  --eval '(progn (require (quote package)) (package-initialize) (require (quote package-lint)))' \
	  -f package-lint-batch-and-exit openclaw-sessions.el

clean:
	$(RM) *.elc test/*.elc
