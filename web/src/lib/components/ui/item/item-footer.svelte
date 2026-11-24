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
	data-slot="item-footer"
	class={cn("flex basis-full items-center justify-between gap-2", className)}
	{...restProps}
>
	{@render children?.()}
</div>
