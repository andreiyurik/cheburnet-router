<script>
	import { cn } from "$lib/utils.js";

	let {
		ref = $bindable(null),
		class: className,
		children,
		...restProps
	} = $props();
</script>

<div
	bind:this={ref}
	data-slot="empty-content"
	class={cn(
		"flex w-full max-w-sm min-w-0 flex-col items-center gap-4 text-sm text-balance",
		className
	)}
	{...restProps}
>
	{@render children?.()}
</div>
