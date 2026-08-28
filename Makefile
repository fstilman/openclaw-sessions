EMACS ?= emacs
ELFILES = openclaw-sessions.el openclaw-sessions-context.el \
	openclaw-sessions-org.el openclaw-sessions-mu4e.el

.PHONY: test compile checkdoc package-lint clean

test:
	$(EMACS) -Q --batch -L . -L test \
	  -l test/openclaw-sessions-test.el \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile $(ELFILES)

checkdoc:
	$(EMACS) -Q --batch -L . \
	  --eval '(progn (require (quote checkdoc)) (mapc (function checkdoc-file) command-line-args-left))' \
	  $(ELFILES)

package-lint:
	$(EMACS) -Q --batch -L . \
	  --eval '(progn (require (quote package)) (package-initialize) (require (quote package-lint)))' \
	  -f package-lint-batch-and-exit openclaw-sessions.el

clean:
	$(RM) *.elc test/*.elc
