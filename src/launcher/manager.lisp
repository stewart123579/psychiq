(in-package :cl-user)
(defpackage psychiq.launcher.manager
  (:use #:cl
        #:psychiq.launcher.processor
        #:psychiq.specials)
  (:import-from #:alexandria
                #:when-let)
  (:export #:manager
           #:make-manager
           #:manager-stopped-p
           #:start
           #:stop
           #:kill))
(in-package :psychiq.launcher.manager)

(defstruct (manager (:constructor %make-manager))
  host
  port
  (queues '())
  (count 25)
  (children '())
  (lock (bt:make-recursive-lock))
  (stopped-p t)
  make-processor-fn)

(defun make-manager (&key (host *default-redis-host*) (port *default-redis-port*) queues (count 25) (timeout 5))
  (let ((manager (%make-manager :host host :port port :queues queues
                                :count count)))
    (setf (manager-make-processor-fn manager)
          (lambda ()
            (make-processor :host host
                            :port port
                            :queues queues
                            :manager manager
                            :timeout timeout)))
    manager))

(defun make-child-processors (manager)
  (bt:with-recursive-lock-held ((manager-lock manager))
    (setf (manager-children manager)
          (loop repeat (manager-count manager)
                collect (funcall (manager-make-processor-fn manager))))))

(defun processor-stopped (manager processor)
  (bt:with-recursive-lock-held ((manager-lock manager))
    (setf (manager-children manager)
          (delete processor (manager-children manager) :test #'eq))
    (when (null (manager-children manager))
      (setf (manager-stopped-p manager) t)))
  (values))

(defun processor-died (manager processor e)
  (bt:with-recursive-lock-held ((manager-lock manager))
    (stop processor)
    (setf (manager-children manager)
          (delete processor (manager-children manager) :test #'eq))
    (unless (manager-stopped-p manager)
      (vom:warn "Processor died with ~S: ~A" (class-name (class-of e)) e)
      (vom:debug "Adding a new processor...")
      (let ((new-processor
              (funcall (manager-make-processor-fn manager))))
        (push new-processor (manager-children manager))
        (start new-processor))))
  (values))

(defmethod run :around ((processor processor))
  (handler-case (call-next-method)
    (error (e)
      (when-let (manager (processor-manager processor))
        (processor-died manager processor e))))
  (vom:debug "Shutting down a processor..."))

(defmethod finalize :after ((processor processor))
  (when-let (manager (processor-manager processor))
    (processor-stopped manager processor)))

(defmethod start ((manager manager))
  (setf (manager-stopped-p manager) nil)
  (make-child-processors manager)
  (map nil #'start (manager-children manager))
  manager)

(defmethod stop ((manager manager))
  (when (manager-stopped-p manager)
    (return-from stop nil))

  (setf (manager-stopped-p manager) t)
  (vom:info "Terminating quiet processors...")
  (map nil #'stop (manager-children manager))
  (vom:info "Exiting...")
  t)

(defmethod kill ((manager manager))
  (setf (manager-stopped-p manager) t)
  (vom:info "Terminating all processors...")
  (map nil #'kill (manager-children manager))
  (vom:info "Exiting...")
  t)