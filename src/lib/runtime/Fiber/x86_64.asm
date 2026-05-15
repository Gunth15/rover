.global switch_context
.type switch_context @function
switch_context:
  pushq %rbx
  pushq %rbp
  pushq %r12
  pushq %r13
  pushq %r14
  pushq %r15

  #change to new stack
  movq %rsp, (%rdi)
  movq (%rsi), %rsp

  popq %r15
  popq %r14
  popq %r13
  popq %r12
  popq %rbp
  popq %rbx

  ret
