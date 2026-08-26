;;; openclaw-sessions-test.el --- Tests for openclaw-sessions -*- lexical-binding: t; -*-

(require 'ert)
(require 'openclaw-sessions)
(require 'term)

;; Launcher tests replace the vterm entry points without loading its module.
(provide 'vterm)
(provide 'eat)

(ert-deftest openclaw-sessions-test-session-parts ()
  (should (equal (openclaw-sessions--session-parts
                  "agent:main:issue-2540-navigation-layout")
                 '("main" "issue-2540-navigation-layout")))
  (should (equal (openclaw-sessions--session-parts
                  "agent:work:name:with:colons")
                 '("work" "name:with:colons")))
  (should-not (openclaw-sessions--session-parts "global")))

(ert-deftest openclaw-sessions-test-parse-json-buffer ()
  (with-temp-buffer
    (insert "diagnostic line\n{\"sessions\":[{\"key\":\"agent:main:test\",\"status\":\"done\"}]}")
    (let ((sessions (openclaw-sessions--parse-json-buffer)))
      (should (= (length sessions) 1))
      (should (equal (alist-get 'status (car sessions)) "done")))))

(ert-deftest openclaw-sessions-test-format-age ()
  (should (equal (openclaw-sessions--format-age '((ageMs . 12000))) "12s"))
  (should (equal (openclaw-sessions--format-age '((ageMs . 120000))) "2m"))
  (should (equal (openclaw-sessions--format-age '((ageMs . 7200000))) "2h")))

(ert-deftest openclaw-sessions-test-format-tokens ()
  (should (equal (openclaw-sessions--format-tokens
                  '((totalTokens . 50000) (contextTokens . 200000)))
                 "50k/200k (25%)"))
  (should (equal (openclaw-sessions--format-tokens '()) "—")))

(ert-deftest openclaw-sessions-test-mode-line-counts-managed-statuses ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:topic")
            (kind . "direct") (status . "running"))))
        (openclaw-sessions-dashboard-scope 'managed))
    (with-temp-buffer
      (setq-local openclaw-sessions--session-name "topic"
                  openclaw-sessions--session-key "agent:main:topic")
      (should (equal (substring-no-properties
                      (openclaw-sessions-mode-line-string))
                     "   OC:1▶ 0✓")))))

(ert-deftest openclaw-sessions-test-mode-line-respects-direct-scope ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:direct")
            (kind . "direct") (status . "running"))
           ((key . "agent:main:cron")
            (kind . "cron") (status . "done"))))
        (openclaw-sessions-dashboard-scope 'direct))
    (should (equal (substring-no-properties
                    (openclaw-sessions-mode-line-string))
                   "   OC:1▶ 0✓"))))

(ert-deftest openclaw-sessions-test-mode-line-respects-all-scope ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:direct")
            (kind . "direct") (status . "running"))
           ((key . "agent:main:cron")
            (kind . "cron") (status . "done"))))
        (openclaw-sessions-dashboard-scope 'all))
    (should (equal (substring-no-properties
                    (openclaw-sessions-mode-line-string))
                   "   OC:1▶ 1✓"))))

(ert-deftest openclaw-sessions-test-mode-line-shows-unreviewed-count ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:topic")
            (kind . "direct") (status . "done"))))
        (openclaw-sessions--unseen-completions
         (make-hash-table :test #'equal))
        (openclaw-sessions-dashboard-scope 'direct))
    (puthash "agent:main:topic" "done"
             openclaw-sessions--unseen-completions)
    (should (equal (substring-no-properties
                    (openclaw-sessions-mode-line-string))
                   "   OC:0▶ 1✓ 1●"))))

(ert-deftest openclaw-sessions-test-cycle-scope-is-global ()
  (let ((openclaw-sessions-dashboard-scope 'managed))
    (cl-letf (((symbol-function 'openclaw-sessions--update-dashboard) #'ignore)
              ((symbol-function 'force-mode-line-update) #'ignore))
      (openclaw-sessions-cycle-scope)
      (should (eq openclaw-sessions-dashboard-scope 'direct))
      (openclaw-sessions-cycle-scope)
      (should (eq openclaw-sessions-dashboard-scope 'all))
      (openclaw-sessions-cycle-scope)
      (should (eq openclaw-sessions-dashboard-scope 'managed)))))

(ert-deftest openclaw-sessions-test-agent-reader-uses-completion ()
  (let (completion-arguments)
    (cl-letf (((symbol-function 'openclaw-sessions--agent-candidates)
               (lambda () '("main" "work")))
              ((symbol-function 'completing-read)
               (lambda (&rest arguments)
                 (setq completion-arguments arguments)
                 "work")))
      (should (equal (openclaw-sessions-read-agent) "work"))
      (should (equal (nth 1 completion-arguments) '("main" "work")))
      (should-not (nth 3 completion-arguments)))))

(ert-deftest openclaw-sessions-test-agent-reader-allows-automatic ()
  (cl-letf (((symbol-function 'openclaw-sessions--agent-candidates)
             (lambda () '("main")))
            ((symbol-function 'completing-read)
             (lambda (&rest _) "")))
    (should-not (openclaw-sessions-read-agent))))

(ert-deftest openclaw-sessions-test-auto-backend-preference ()
  (let ((openclaw-sessions-terminal-backend 'auto)
        available)
    (cl-letf (((symbol-function 'openclaw-sessions--backend-available-p)
               (lambda (backend) (memq backend available))))
      (setq available '(vterm eat term))
      (should (eq (openclaw-sessions--resolved-terminal-backend) 'vterm))
      (setq available '(eat term))
      (should (eq (openclaw-sessions--resolved-terminal-backend) 'eat))
      (setq available '(term))
      (should (eq (openclaw-sessions--resolved-terminal-backend) 'term)))))

(ert-deftest openclaw-sessions-test-custom-backend-contract ()
  (let (received
        created-buffer)
    (unwind-protect
        (let ((openclaw-sessions-terminal-backend
               (lambda (name executable arguments directory)
                 (setq received (list name executable arguments directory)
                       created-buffer (generate-new-buffer " *oc-custom*"))
                 created-buffer)))
          (should (eq (openclaw-sessions--launch-terminal
                       "work/topic" "/usr/bin/openclaw"
                       '("tui" "--session" "agent:work:topic") "/tmp/")
                      created-buffer))
          (should (equal received
                         '("work/topic" "/usr/bin/openclaw"
                           ("tui" "--session" "agent:work:topic")
                           "/tmp/"))))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest openclaw-sessions-test-eat-backend-passes-argv ()
  (let (received
        created-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'eat-make)
                   (lambda (name executable startfile &rest arguments)
                     (setq received
                           (list name executable startfile arguments)
                           created-buffer
                           (generate-new-buffer " *oc-eat*"))
                     created-buffer))
                  ((symbol-function 'eat-char-mode) #'ignore)
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (should (eq (openclaw-sessions--launch-eat
                       "topic" "/usr/bin/openclaw"
                       '("tui" "--session" "topic") "/tmp/")
                      created-buffer))
          (should (equal received
                         '("openclaw:topic" "/usr/bin/openclaw" nil
                           ("tui" "--session" "topic")))))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest openclaw-sessions-test-term-backend-passes-argv ()
  (let (received
        created-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'make-term)
                   (lambda (name executable startfile &rest arguments)
                     (setq received
                           (list name executable startfile arguments)
                           created-buffer
                           (generate-new-buffer " *oc-term*"))
                     created-buffer))
                  ((symbol-function 'term-mode) #'ignore)
                  ((symbol-function 'term-char-mode) #'ignore)
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (should (eq (openclaw-sessions--launch-term
                       "topic" "/usr/bin/openclaw"
                       '("tui" "--session" "topic") "/tmp/")
                      created-buffer))
          (should (equal received
                         '("openclaw:topic" "/usr/bin/openclaw" nil
                           ("tui" "--session" "topic")))))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest openclaw-sessions-test-managed-dashboard-filter ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:managed")
            (kind . "direct") (status . "running"))
           ((key . "agent:main:other")
            (kind . "direct") (status . "done"))))
        (openclaw-sessions-dashboard-scope 'managed))
    (with-temp-buffer
      (setq-local openclaw-sessions--session-name "managed"
                  openclaw-sessions--session-key "agent:main:managed")
      (let ((rows (openclaw-sessions--dashboard-entries)))
        (should (= (length rows) 1))
        (should (equal (caar rows) "agent:main:managed"))))))

(ert-deftest openclaw-sessions-test-notifies-running-to-terminal-only ()
  (let ((openclaw-sessions--sessions
        '(((key . "agent:main:test") (status . "done"))))
        (openclaw-sessions--statuses (make-hash-table :test #'equal))
        (openclaw-sessions--unseen-completions
         (make-hash-table :test #'equal))
        (openclaw-sessions-notify-on-completion t)
        notified)
    (with-temp-buffer
      (setq-local openclaw-sessions--session-name "test"
                  openclaw-sessions--session-key "agent:main:test")
      (puthash "agent:main:test" "running" openclaw-sessions--statuses)
      (cl-letf (((symbol-function 'openclaw-sessions--notify)
                 (lambda (&rest _) (setq notified t))))
        (openclaw-sessions--record-status-transitions)
        (should notified)))))

(ert-deftest openclaw-sessions-test-running-to-terminal-becomes-unreviewed ()
  (let ((openclaw-sessions--sessions
         '(((key . "agent:main:test") (status . "done"))))
        (openclaw-sessions--statuses (make-hash-table :test #'equal))
        (openclaw-sessions--unseen-completions
         (make-hash-table :test #'equal))
        (openclaw-sessions-notify-on-completion nil))
    (openclaw-sessions--record-status-transitions)
    (should-not (openclaw-sessions--unseen-p "agent:main:test"))
    (puthash "agent:main:test" "running" openclaw-sessions--statuses)
    (openclaw-sessions--record-status-transitions)
    (should (equal (openclaw-sessions--unseen-p "agent:main:test")
                   "done"))))

(ert-deftest openclaw-sessions-test-review-state-can-be-changed-explicitly ()
  (let ((openclaw-sessions--unseen-completions
         (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'openclaw-sessions--update-dashboard) #'ignore)
              ((symbol-function 'force-mode-line-update) #'ignore))
      (openclaw-sessions--set-unseen "agent:main:test" t)
      (should (openclaw-sessions--unseen-p "agent:main:test"))
      (openclaw-sessions--set-unseen "agent:main:test" nil)
      (should-not (openclaw-sessions--unseen-p "agent:main:test")))))

(ert-deftest openclaw-sessions-test-visiting-managed-buffer-reviews-completion ()
  (let ((openclaw-sessions--unseen-completions
         (make-hash-table :test #'equal)))
    (with-temp-buffer
      (setq-local openclaw-sessions--session-key "agent:main:test")
      (puthash openclaw-sessions--session-key "done"
               openclaw-sessions--unseen-completions)
      (openclaw-sessions--prepare-managed-buffer)
      (should (memq #'openclaw-sessions--review-current-buffer-completion
                    post-command-hook))
      (cl-letf (((symbol-function 'openclaw-sessions--update-dashboard) #'ignore)
                ((symbol-function 'force-mode-line-update) #'ignore))
        (openclaw-sessions--review-current-buffer-completion))
      (should-not (openclaw-sessions--unseen-p
                   openclaw-sessions--session-key)))))

(ert-deftest openclaw-sessions-test-launches-name-without-directory-prompt ()
  (let ((openclaw-sessions-default-agent nil)
        (openclaw-sessions-launch-directory nil)
        (openclaw-sessions-terminal-backend 'vterm)
        (default-directory "/tmp/")
        sent-command
        created-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'openclaw-sessions--executable)
                   (lambda () "/usr/bin/openclaw"))
                  ((symbol-function 'openclaw-sessions-monitor-mode)
                   (lambda (&optional _)))
                  ((symbol-function 'vterm)
                   (lambda (name)
                     (setq sent-command vterm-shell)
                     (setq created-buffer (get-buffer-create name))
                     (set-buffer created-buffer))))
          (openclaw-sessions-start "my-topic")
          (should (equal sent-command
                         "/usr/bin/openclaw tui --session my-topic"))
          (should (equal
                   (buffer-local-value 'openclaw-sessions--session-name
                                       created-buffer)
                   "my-topic"))
          (should-not
           (buffer-local-value 'openclaw-sessions--session-agent
                               created-buffer)))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest openclaw-sessions-test-explicit-agent-uses-full-key ()
  (let ((openclaw-sessions-default-agent nil)
        (openclaw-sessions-launch-directory "/tmp/")
        (openclaw-sessions-terminal-backend 'vterm)
        sent-command
        created-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'openclaw-sessions--executable)
                   (lambda () "/usr/bin/openclaw"))
                  ((symbol-function 'openclaw-sessions-monitor-mode)
                   (lambda (&optional _)))
                  ((symbol-function 'vterm)
                   (lambda (name)
                     (setq sent-command vterm-shell)
                     (setq created-buffer (get-buffer-create name))
                     (set-buffer created-buffer))))
          (openclaw-sessions-start "my-topic" "work")
          (should (equal sent-command
                         "/usr/bin/openclaw tui --session agent\\:work\\:my-topic"))
          (should (equal
                   (buffer-local-value 'openclaw-sessions--session-key
                                       created-buffer)
                   "agent:work:my-topic")))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(provide 'openclaw-sessions-test)

;;; openclaw-sessions-test.el ends here
