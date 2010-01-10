;;; transformation of letrec into simpler forms

;; Copyright (C) 2009 Free Software Foundation, Inc.

;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;; 
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;; 
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

(define-module (language tree-il fix-letrec)
  #:use-module (system base syntax)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (language tree-il)
  #:use-module (language tree-il primitives)
  #:export (fix-letrec!))

;; For a detailed discussion, see "Fixing Letrec: A Faithful Yet
;; Efficient Implementation of Scheme’s Recursive Binding Construct", by
;; Oscar Waddell, Dipanwita Sarkar, and R. Kent Dybvig.

(define fix-fold
  (make-tree-il-folder unref ref set simple lambda complex))

(define (simple-expression? x bound-vars)
  (record-case x
    ((<void>) #t)
    ((<const>) #t)
    ((<lexical-ref> gensym)
     (not (memq gensym bound-vars)))
    ((<conditional> test consequent alternate)
     (and (simple-expression? test bound-vars)
          (simple-expression? consequent bound-vars)
          (simple-expression? alternate bound-vars)))
    ((<sequence> exps)
     (and-map (lambda (x) (simple-expression? x bound-vars))
              exps))
    ((<application> proc args)
     (and (primitive-ref? proc)
          (effect-free-primitive? (primitive-ref-name proc))
          (and-map (lambda (x) (simple-expression? x bound-vars))
                   args)))
    (else #f)))

(define (partition-vars x)
  (let-values
      (((unref ref set simple lambda* complex)
        (fix-fold x
                  (lambda (x unref ref set simple lambda* complex)
                    (record-case x
                      ((<lexical-ref> gensym)
                       (values (delq gensym unref)
                               (lset-adjoin eq? ref gensym)
                               set
                               simple
                               lambda*
                               complex))
                      ((<lexical-set> gensym)
                       (values unref
                               ref
                               (lset-adjoin eq? set gensym)
                               simple
                               lambda*
                               complex))
                      ((<letrec> vars)
                       (values (append vars unref)
                               ref
                               set
                               simple
                               lambda*
                               complex))
                      ((<let> vars)
                       (values (append vars unref)
                               ref
                               set
                               simple
                               lambda*
                               complex))
                      (else
                       (values unref ref set simple lambda* complex))))
                  (lambda (x unref ref set simple lambda* complex)
                    (record-case x
                      ((<letrec> (orig-vars vars) vals)
                       (let lp ((vars orig-vars) (vals vals)
                                (s '()) (l '()) (c '()))
                         (cond
                          ((null? vars)
                           (values unref
                                   ref
                                   set
                                   (append s simple)
                                   (append l lambda*)
                                   (append c complex)))
                          ((memq (car vars) unref)
                           (lp (cdr vars) (cdr vals)
                               s l c))
                          ((memq (car vars) set)
                           (lp (cdr vars) (cdr vals)
                               s l (cons (car vars) c)))
                          ((lambda? (car vals))
                           (lp (cdr vars) (cdr vals)
                               s (cons (car vars) l) c))
                          ((simple-expression? (car vals) orig-vars)
                           (lp (cdr vars) (cdr vals)
                               (cons (car vars) s) l c))
                          (else
                           (lp (cdr vars) (cdr vals)
                               s l (cons (car vars) c))))))
                      ((<let> (orig-vars vars) vals)
                       ;; The point is to compile let-bound lambdas as
                       ;; efficiently as we do letrec-bound lambdas, so
                       ;; we use the same algorithm for analyzing the
                       ;; vars. There is no problem recursing into the
                       ;; bindings after the let, because all variables
                       ;; have been renamed.
                       (let lp ((vars orig-vars) (vals vals)
                                (s '()) (l '()) (c '()))
                         (cond
                          ((null? vars)
                           (values unref
                                   ref
                                   set
                                   (append s simple)
                                   (append l lambda*)
                                   (append c complex)))
                          ((memq (car vars) unref)
                           (lp (cdr vars) (cdr vals)
                               s l c))
                          ((memq (car vars) set)
                           (lp (cdr vars) (cdr vals)
                               s l (cons (car vars) c)))
                          ((and (lambda? (car vals))
                                (not (memq (car vars) set)))
                           (lp (cdr vars) (cdr vals)
                               s (cons (car vars) l) c))
                          ;; There is no difference between simple and
                          ;; complex, for the purposes of let. Just lump
                          ;; them all into complex.
                          (else
                           (lp (cdr vars) (cdr vals)
                               s l (cons (car vars) c))))))
                      (else
                       (values unref ref set simple lambda* complex))))
                  '()
                  '()
                  '()
                  '()
                  '()
                  '())))
    (values unref simple lambda* complex)))

(define (fix-letrec! x)
  (let-values (((unref simple lambda* complex) (partition-vars x)))
    (post-order!
     (lambda (x)
       (record-case x

         ;; Sets to unreferenced variables may be replaced by their
         ;; expression, called for effect.
         ((<lexical-set> gensym exp)
          (if (memq gensym unref)
              (make-sequence #f (list exp (make-void #f)))
              x))

         ((<letrec> src names vars vals body)
          (let ((binds (map list vars names vals)))
            (define (lookup set)
              (map (lambda (v) (assq v binds))
                   (lset-intersection eq? vars set)))
            (let ((u (lookup unref))
                  (s (lookup simple))
                  (l (lookup lambda*))
                  (c (lookup complex)))
              ;; Bind "simple" bindings, and locations for complex
              ;; bindings.
              (make-let
               src
               (append (map cadr s) (map cadr c))
               (append (map car s) (map car c))
               (append (map caddr s) (map (lambda (x) (make-void #f)) c))
               ;; Bind lambdas using the fixpoint operator.
               (make-fix
                src (map cadr l) (map car l) (map caddr l)
                (make-sequence
                 src
                 (append
                  ;; The right-hand-sides of the unreferenced
                  ;; bindings, for effect.
                  (map caddr u)
                  (if (null? c)
                      ;; No complex bindings, just emit the body.
                      (list body)
                      (list
                       ;; Evaluate the the "complex" bindings, in a `let' to
                       ;; indicate that order doesn't matter, and bind to
                       ;; their variables.
                       (let ((tmps (map (lambda (x) (gensym)) c)))
                         (make-let
                          #f (map cadr c) tmps (map caddr c)
                          (make-sequence
                           #f
                           (map (lambda (x tmp)
                                  (make-lexical-set
                                   #f (cadr x) (car x)
                                   (make-lexical-ref #f (cadr x) tmp)))
                                c tmps))))
                       ;; Finally, the body.
                       body)))))))))

         ((<let> src names vars vals body)
          (let ((binds (map list vars names vals)))
            (define (lookup set)
              (map (lambda (v) (assq v binds))
                   (lset-intersection eq? vars set)))
            (let ((u (lookup unref))
                  (l (lookup lambda*))
                  (c (lookup complex)))
              (make-sequence
               src
               (append
                ;; unreferenced bindings, called for effect.
                (map caddr u)
                (list
                 ;; unassigned lambdas use fix.
                 (make-fix src (map cadr l) (map car l) (map caddr l)
                           ;; and the "complex" bindings.
                           (make-let src (map cadr c) (map car c) (map caddr c)
                                     body))))))))
         
         (else x)))
     x)))